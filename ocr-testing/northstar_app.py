"""
NorthStar OCR Application
Two modes:
  1. Report Mode  – Upload an image or PDF, run all models, generate a full report
  2. Live Detection Mode – Real-time camera feed with YOLO + OCR + BLIP
"""

import cv2
import easyocr
import threading
import time
import torch
import queue
import math
import os
import sys
import numpy as np
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from PIL import Image, ImageTk
from ultralytics import YOLO
from transformers import BlipProcessor, BlipForConditionalGeneration
import fitz  # PyMuPDF

# ─── Paths ────────────────────────────────────────────────────────────────────
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
YOLO_MODEL_PATH = os.path.join(BASE_DIR, "yolov8s.pt")

# ─── Configuration ────────────────────────────────────────────────────────────
OCR_TRIGGERS = [
    "book", "traffic light", "stop sign", "parking meter",
    "remote", "cell phone", "laptop", "monitor", "tv",
    "clock", "sign", "screen", "menu", "bottle", "cup",
]
OCR_COOLDOWN = 1.0
LOCK_TIMEOUT = 3.0
CENTER_BIAS_WEIGHT = 2.0

# ─── Shared model loading (lazy singletons) ──────────────────────────────────
_models = {}
_model_lock = threading.Lock()


def get_yolo():
    with _model_lock:
        if "yolo" not in _models:
            _models["yolo"] = YOLO(YOLO_MODEL_PATH)
    return _models["yolo"]


def get_easyocr():
    with _model_lock:
        if "easyocr" not in _models:
            _models["easyocr"] = easyocr.Reader(["en"], gpu=False)
    return _models["easyocr"]


def get_blip():
    with _model_lock:
        if "blip" not in _models:
            proc = BlipProcessor.from_pretrained(
                "Salesforce/blip-image-captioning-base"
            )
            model = BlipForConditionalGeneration.from_pretrained(
                "Salesforce/blip-image-captioning-base"
            )
            _models["blip"] = (proc, model)
    return _models["blip"]


# ═════════════════════════════════════════════════════════════════════════════
#  REPORT MODE LOGIC
# ═════════════════════════════════════════════════════════════════════════════

def load_images_from_file(path):
    """Return a list of (page_label, PIL.Image) from an image or PDF."""
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        doc = fitz.open(path)
        images = []
        for i, page in enumerate(doc):
            pix = page.get_pixmap(dpi=200)
            img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
            images.append((f"Page {i + 1}", img))
        doc.close()
        return images
    else:
        img = Image.open(path).convert("RGB")
        return [(os.path.basename(path), img)]


def run_report(pil_image):
    """Run all three models on a single PIL image. Returns dict of results."""
    cv_img = cv2.cvtColor(np.array(pil_image), cv2.COLOR_RGB2BGR)
    results = {}

    # 1. BLIP – scene caption
    try:
        proc, model = get_blip()
        inputs = proc(images=pil_image, return_tensors="pt")
        with torch.no_grad():
            out = model.generate(**inputs, max_new_tokens=50)
        results["BLIP Scene Caption"] = proc.decode(out[0], skip_special_tokens=True).capitalize()
    except Exception as e:
        results["BLIP Scene Caption"] = f"Error: {e}"

    # 2. YOLOv8 – object detection
    try:
        yolo = get_yolo()
        det = yolo(cv_img, verbose=False)
        lines = []
        for r in det:
            for box in r.boxes:
                label = yolo.names[int(box.cls[0])]
                conf = float(box.conf[0])
                x1, y1, x2, y2 = map(int, box.xyxy[0])
                lines.append(f"  {label} ({conf:.0%})  [{x1},{y1},{x2},{y2}]")
        results["YOLOv8 Detections"] = "\n".join(lines) if lines else "No objects detected."
    except Exception as e:
        results["YOLOv8 Detections"] = f"Error: {e}"

    # 3. EasyOCR – text extraction
    try:
        reader = get_easyocr()
        # Enhance for better OCR
        gray = cv2.cvtColor(cv_img, cv2.COLOR_BGR2GRAY)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        enhanced = clahe.apply(gray)
        ocr_results = reader.readtext(enhanced, detail=1, paragraph=False)
        lines = []
        for bbox, text, conf in ocr_results:
            lines.append(f"  [{conf:.0%}] {text}")
        results["EasyOCR Text"] = "\n".join(lines) if lines else "No text detected."
    except Exception as e:
        results["EasyOCR Text"] = f"Error: {e}"

    return results


# ═════════════════════════════════════════════════════════════════════════════
#  LIVE DETECTION LOGIC (adapted from northstar-vision.py)
# ═════════════════════════════════════════════════════════════════════════════

class SmoothingFilter:
    def __init__(self):
        self.history = {}

    def smooth(self, label, new_box):
        if label not in self.history:
            self.history[label] = new_box
            return new_box
        prev = self.history[label]
        alpha = 0.3
        s = tuple(int(p * (1 - alpha) + n * alpha) for p, n in zip(prev, new_box))
        self.history[label] = s
        return s


class LiveDetector:
    """Runs the live camera detection loop, pushing frames to a callback."""

    def __init__(self, frame_callback, status_callback, camera_index=0):
        self.frame_cb = frame_callback
        self.status_cb = status_callback
        self.camera_index = camera_index
        self.running = False
        self._thread = None

        # OCR worker
        self._ocr_queue = queue.Queue(maxsize=1)
        self._ocr_text = ""
        self._ocr_lock = threading.Lock()
        self._ocr_thread = threading.Thread(target=self._ocr_loop, daemon=True)
        self._ocr_thread.start()

        # Scene brain
        self._scene_desc = "Analyzing scene..."
        self._scene_lock = threading.Lock()

        self.smoother = SmoothingFilter()
        self.locked_label = None
        self.locked_box = None
        self.last_seen_time = 0
        self.last_ocr_time = 0

    # --- OCR background worker ---
    def _ocr_loop(self):
        reader = get_easyocr()
        while True:
            roi = self._ocr_queue.get()
            try:
                h, w = roi.shape[:2]
                if h < 300:
                    roi = cv2.resize(roi, (0, 0), fx=1.5, fy=1.5)
                texts = reader.readtext(roi, detail=0, paragraph=True)
                with self._ocr_lock:
                    self._ocr_text = " ".join(texts)
            except:
                pass
            finally:
                self._ocr_queue.task_done()

    def _request_ocr(self, roi):
        if not self._ocr_queue.full():
            self._ocr_queue.put(roi)

    # --- Scene brain ---
    def _analyze_scene(self, frame):
        try:
            proc, model = get_blip()
            pil = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            inputs = proc(images=pil, return_tensors="pt")
            with torch.no_grad():
                out = model.generate(**inputs, max_new_tokens=30)
            desc = proc.decode(out[0], skip_special_tokens=True).capitalize()
            with self._scene_lock:
                self._scene_desc = desc
        except:
            pass

    # --- Focus score ---
    @staticmethod
    def _focus_score(box, w, h):
        x1, y1, x2, y2 = box
        area_score = ((x2 - x1) * (y2 - y1)) / (w * h)
        bcx, bcy = (x1 + x2) / 2, (y1 + y2) / 2
        dist = math.sqrt((bcx - w / 2) ** 2 + (bcy - h / 2) ** 2)
        max_dist = math.sqrt((w / 2) ** 2 + (h / 2) ** 2)
        center_score = 1.0 - dist / max_dist
        return area_score + center_score * CENTER_BIAS_WEIGHT

    # --- Main loop ---
    def start(self):
        if self.running:
            return
        self.running = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self.running = False

    def _run(self):
        yolo = get_yolo()
        cap = cv2.VideoCapture(self.camera_index)
        cap.set(cv2.CAP_PROP_FPS, 30)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

        if not cap.isOpened():
            self.status_cb("ERROR: Could not open camera.")
            self.running = False
            return

        self.status_cb("Live detection running – press Stop to end.")
        scene_timer = 0

        while self.running:
            ret, frame = cap.read()
            if not ret:
                break

            h, w = frame.shape[:2]
            display = frame.copy()

            # Crosshair
            cx, cy = w // 2, h // 2
            cv2.line(display, (cx - 20, cy), (cx + 20, cy), (200, 200, 200), 1)
            cv2.line(display, (cx, cy - 20), (cx, cy + 20), (200, 200, 200), 1)

            # YOLO
            results = yolo(frame, verbose=False, stream=True)
            candidates = []
            for r in results:
                for box in r.boxes:
                    label = yolo.names[int(box.cls[0])]
                    if float(box.conf[0]) < 0.5:
                        continue
                    if label in OCR_TRIGGERS:
                        coords = tuple(map(int, box.xyxy[0]))
                        score = self._focus_score(coords, w, h)
                        candidates.append((label, coords, score))

            # Lock logic
            best = None
            if self.locked_label:
                matches = [c for c in candidates if c[0] == self.locked_label]
                if matches:
                    best = max(matches, key=lambda x: x[2])
                    self.last_seen_time = time.time()
                elif time.time() - self.last_seen_time > LOCK_TIMEOUT:
                    self.locked_label = None
                    self.locked_box = None

            if not self.locked_label and candidates:
                best = max(candidates, key=lambda x: x[2])
                if best[2] > 0.8:
                    self.locked_label = best[0]
                    self.last_seen_time = time.time()

            # Draw non-locked
            for lbl, bx, sc in candidates:
                if lbl != self.locked_label:
                    x1, y1, x2, y2 = bx
                    cv2.rectangle(display, (x1, y1), (x2, y2), (100, 50, 0), 1)

            # Draw locked
            if best and self.locked_label:
                lbl, raw_box, sc = best
                self.locked_box = self.smoother.smooth(lbl, raw_box)
                x1, y1, x2, y2 = self.locked_box
                obj_cx, obj_cy = (x1 + x2) // 2, (y1 + y2) // 2
                cv2.line(display, (cx, cy), (obj_cx, obj_cy), (0, 255, 0), 2)
                cv2.rectangle(display, (x1, y1), (x2, y2), (0, 255, 0), 3)
                cv2.putText(display, f"LOCKED: {lbl}", (x1, y1 - 15),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)

                # OCR
                if time.time() - self.last_ocr_time > OCR_COOLDOWN:
                    roi = frame[max(0, y1 - 10):min(h, y2 + 10),
                                max(0, x1 - 10):min(w, x2 + 10)]
                    self._request_ocr(roi.copy())
                    self.last_ocr_time = time.time()

            # OCR text overlay
            with self._ocr_lock:
                text = self._ocr_text
            if self.locked_label and len(text) > 2:
                cv2.rectangle(display, (0, h - 80), (w, h), (0, 0, 0), -1)
                cv2.putText(display, f"READING: {text}", (30, h - 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)

            # Scene description (every ~5s)
            if time.time() - scene_timer > 5:
                threading.Thread(target=self._analyze_scene,
                                 args=(frame.copy(),), daemon=True).start()
                scene_timer = time.time()

            with self._scene_lock:
                desc = self._scene_desc
            cv2.rectangle(display, (0, 0), (w, 40), (0, 0, 0), -1)
            cv2.putText(display, f"SCENE: {desc}", (10, 30),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 255), 1)

            # Convert to RGB for tkinter
            rgb = cv2.cvtColor(display, cv2.COLOR_BGR2RGB)
            self.frame_cb(rgb)

        cap.release()
        self.running = False
        self.status_cb("Live detection stopped.")


# ═════════════════════════════════════════════════════════════════════════════
#  UI
# ═════════════════════════════════════════════════════════════════════════════

class NorthStarApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("NorthStar OCR")
        self.geometry("1100x750")
        self.minsize(900, 600)
        self.configure(bg="#1e1e2e")
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        self._style_setup()

        # ── Header ──
        header = tk.Frame(self, bg="#181825", height=50)
        header.pack(fill="x")
        header.pack_propagate(False)
        tk.Label(header, text="NORTHSTAR OCR", font=("Segoe UI", 16, "bold"),
                 bg="#181825", fg="#cdd6f4").pack(side="left", padx=16)

        # ── Mode selector ──
        self._mode_var = tk.StringVar(value="report")
        mode_frame = tk.Frame(header, bg="#181825")
        mode_frame.pack(side="right", padx=16)
        for text, val in [("Report Mode", "report"), ("Live Detection", "live")]:
            rb = ttk.Radiobutton(mode_frame, text=text, variable=self._mode_var,
                                 value=val, command=self._switch_mode,
                                 style="Mode.TRadiobutton")
            rb.pack(side="left", padx=8)

        # ── Main body (stacked frames) ──
        self._body = tk.Frame(self, bg="#1e1e2e")
        self._body.pack(fill="both", expand=True)

        self._report_frame = self._build_report_frame(self._body)
        self._live_frame = self._build_live_frame(self._body)

        self._report_frame.place(relx=0, rely=0, relwidth=1, relheight=1)
        self._live_frame.place(relx=0, rely=0, relwidth=1, relheight=1)

        # ── Status bar ──
        self._status_var = tk.StringVar(value="Ready")
        sb = tk.Label(self, textvariable=self._status_var, anchor="w",
                      bg="#11111b", fg="#a6adc8", font=("Segoe UI", 9), padx=8)
        sb.pack(fill="x", side="bottom")

        self._live_detector = None
        self._switch_mode()

    # ── Styles ──
    def _style_setup(self):
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure("Mode.TRadiobutton", background="#181825",
                        foreground="#cdd6f4", font=("Segoe UI", 11))
        style.map("Mode.TRadiobutton",
                   background=[("active", "#313244")],
                   foreground=[("active", "#f5c2e7")])
        style.configure("Accent.TButton", font=("Segoe UI", 11, "bold"),
                        padding=8)

    # ── Report mode UI ──
    def _build_report_frame(self, parent):
        frame = tk.Frame(parent, bg="#1e1e2e")

        # Left panel – file picker + file list + image preview
        left = tk.Frame(frame, bg="#1e1e2e", width=420)
        left.pack(side="left", fill="y", padx=(12, 4), pady=12)
        left.pack_propagate(False)

        btn_frame = tk.Frame(left, bg="#1e1e2e")
        btn_frame.pack(fill="x", pady=(0, 8))
        ttk.Button(btn_frame, text="Browse File...",
                   command=self._open_file, style="Accent.TButton").pack(
            side="left", fill="x", expand=True)

        # Docs folder file listing
        tk.Label(left, text="docs/", font=("Segoe UI", 10, "bold"),
                 bg="#1e1e2e", fg="#a6adc8", anchor="w").pack(fill="x",
                 pady=(4, 2))

        list_frame = tk.Frame(left, bg="#11111b")
        list_frame.pack(fill="x")

        self._docs_listbox = tk.Listbox(
            list_frame, bg="#11111b", fg="#cdd6f4",
            selectbackground="#45475a", selectforeground="#f5c2e7",
            font=("Consolas", 10), relief="flat", height=6,
            activestyle="none", highlightthickness=0, bd=0,
        )
        docs_scroll = ttk.Scrollbar(list_frame, orient="vertical",
                                    command=self._docs_listbox.yview)
        self._docs_listbox.config(yscrollcommand=docs_scroll.set)
        self._docs_listbox.pack(side="left", fill="both", expand=True)
        docs_scroll.pack(side="right", fill="y")
        self._docs_listbox.bind("<<ListboxSelect>>", self._on_docs_select)
        self._refresh_docs_list()

        self._file_label = tk.Label(left, text="No file selected",
                                    bg="#1e1e2e", fg="#6c7086",
                                    font=("Segoe UI", 9), anchor="w")
        self._file_label.pack(fill="x", pady=(6, 0))

        # Image preview canvas
        self._preview_canvas = tk.Canvas(left, bg="#11111b",
                                         highlightthickness=0)
        self._preview_canvas.pack(fill="both", expand=True, pady=(8, 0))
        self._preview_photo = None  # prevent GC

        # Right panel – results
        right = tk.Frame(frame, bg="#1e1e2e")
        right.pack(side="left", fill="both", expand=True, padx=(4, 12),
                   pady=12)

        results_header = tk.Frame(right, bg="#1e1e2e")
        results_header.pack(fill="x")
        tk.Label(results_header, text="Analysis Results",
                 font=("Segoe UI", 13, "bold"), bg="#1e1e2e",
                 fg="#cdd6f4").pack(side="left")
        self._run_btn = ttk.Button(results_header, text="Run Analysis",
                                   command=self._run_report,
                                   style="Accent.TButton")
        self._run_btn.pack(side="right")

        self._results_text = tk.Text(right, wrap="word", bg="#11111b",
                                     fg="#cdd6f4", font=("Consolas", 10),
                                     insertbackground="#cdd6f4",
                                     relief="flat", padx=10, pady=10)
        self._results_text.pack(fill="both", expand=True, pady=(8, 0))
        self._results_text.config(state="disabled")

        # Tag styles for the results text widget
        self._results_text.tag_configure("heading", font=("Segoe UI", 12, "bold"),
                                         foreground="#f5c2e7",
                                         spacing1=12, spacing3=4)
        self._results_text.tag_configure("subheading", font=("Segoe UI", 10, "bold"),
                                         foreground="#89b4fa",
                                         spacing1=8, spacing3=2)
        self._results_text.tag_configure("body", font=("Consolas", 10),
                                         foreground="#cdd6f4")
        self._results_text.tag_configure("separator", foreground="#45475a")

        self._loaded_images = []  # list of (label, PIL.Image)
        return frame

    # ── Live mode UI ──
    def _build_live_frame(self, parent):
        frame = tk.Frame(parent, bg="#1e1e2e")

        # Controls bar
        ctrl = tk.Frame(frame, bg="#1e1e2e")
        ctrl.pack(fill="x", padx=12, pady=(12, 4))

        self._cam_var = tk.StringVar(value="0")
        tk.Label(ctrl, text="Camera Index:", bg="#1e1e2e", fg="#cdd6f4",
                 font=("Segoe UI", 10)).pack(side="left")
        cam_entry = ttk.Entry(ctrl, textvariable=self._cam_var, width=4)
        cam_entry.pack(side="left", padx=(4, 16))

        self._start_btn = ttk.Button(ctrl, text="Start",
                                     command=self._start_live,
                                     style="Accent.TButton")
        self._start_btn.pack(side="left", padx=4)
        self._stop_btn = ttk.Button(ctrl, text="Stop",
                                    command=self._stop_live,
                                    style="Accent.TButton")
        self._stop_btn.pack(side="left", padx=4)
        self._stop_btn.config(state="disabled")

        # Video display
        self._video_label = tk.Label(frame, bg="#11111b")
        self._video_label.pack(fill="both", expand=True, padx=12, pady=(4, 12))
        self._video_photo = None

        return frame

    # ── Mode switching ──
    def _switch_mode(self):
        mode = self._mode_var.get()
        if mode == "report":
            self._report_frame.lift()
            self._stop_live()
        else:
            self._live_frame.lift()

    # ── Docs folder listing ──
    def _refresh_docs_list(self):
        docs_dir = os.path.join(BASE_DIR, "docs")
        self._docs_listbox.delete(0, "end")
        self._docs_files = []
        if not os.path.isdir(docs_dir):
            return
        valid_ext = (".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".pdf")
        for name in sorted(os.listdir(docs_dir)):
            if name.lower().endswith(valid_ext):
                self._docs_files.append(os.path.join(docs_dir, name))
                self._docs_listbox.insert("end", f"  {name}")

    def _on_docs_select(self, event):
        sel = self._docs_listbox.curselection()
        if not sel:
            return
        path = self._docs_files[sel[0]]
        self._load_file(path)

    # ── Report: open file (browse dialog) ──
    def _open_file(self):
        path = filedialog.askopenfilename(
            filetypes=[("Images & PDFs", "*.png *.jpg *.jpeg *.bmp *.tiff *.tif *.pdf"),
                       ("All files", "*.*")])
        if not path:
            return
        self._load_file(path)

    # ── Report: shared file loader ──
    def _load_file(self, path):
        self._status_var.set(f"Loading {os.path.basename(path)}...")
        self.update_idletasks()

        try:
            self._loaded_images = load_images_from_file(path)
        except Exception as e:
            messagebox.showerror("Error", str(e))
            return

        self._file_label.config(
            text=f"{os.path.basename(path)}  ({len(self._loaded_images)} page(s))")

        # Show first page preview
        self._show_preview(self._loaded_images[0][1])
        self._status_var.set("File loaded. Click 'Run Analysis' to process.")

        # Clear previous results
        self._results_text.config(state="normal")
        self._results_text.delete("1.0", "end")
        self._results_text.config(state="disabled")

    def _show_preview(self, pil_img):
        self._preview_canvas.update_idletasks()
        cw = max(self._preview_canvas.winfo_width(), 200)
        ch = max(self._preview_canvas.winfo_height(), 200)
        img = pil_img.copy()
        img.thumbnail((cw, ch), Image.LANCZOS)
        self._preview_photo = ImageTk.PhotoImage(img)
        self._preview_canvas.delete("all")
        self._preview_canvas.create_image(cw // 2, ch // 2, anchor="center",
                                          image=self._preview_photo)

    # ── Report: run analysis ──
    def _run_report(self):
        if not self._loaded_images:
            messagebox.showinfo("No file", "Open an image or PDF first.")
            return
        self._run_btn.config(state="disabled")
        self._status_var.set("Running analysis (this may take a moment)...")
        self.update_idletasks()
        threading.Thread(target=self._report_worker, daemon=True).start()

    def _report_worker(self):
        all_results = []
        total = len(self._loaded_images)
        for i, (label, pil_img) in enumerate(self._loaded_images):
            self._set_status(f"Processing {label}  ({i + 1}/{total})...")
            results = run_report(pil_img)
            all_results.append((label, results))
        self.after(0, self._display_results, all_results)

    def _display_results(self, all_results):
        tw = self._results_text
        tw.config(state="normal")
        tw.delete("1.0", "end")

        for page_label, results in all_results:
            tw.insert("end", f"═══  {page_label}  ═══\n", "heading")
            for model_name, output in results.items():
                tw.insert("end", f"\n▸ {model_name}\n", "subheading")
                tw.insert("end", f"{output}\n", "body")
            tw.insert("end", "\n" + "─" * 60 + "\n", "separator")

        tw.config(state="disabled")
        self._run_btn.config(state="normal")
        self._status_var.set("Analysis complete.")

    # ── Live detection ──
    def _start_live(self):
        try:
            cam_idx = int(self._cam_var.get())
        except ValueError:
            cam_idx = 0

        self._start_btn.config(state="disabled")
        self._stop_btn.config(state="normal")
        self._status_var.set("Starting live detection...")

        self._live_detector = LiveDetector(
            frame_callback=self._on_live_frame,
            status_callback=self._set_status,
            camera_index=cam_idx,
        )
        self._live_detector.start()

    def _stop_live(self):
        if self._live_detector and self._live_detector.running:
            self._live_detector.stop()
        self._start_btn.config(state="normal")
        self._stop_btn.config(state="disabled")

    def _on_live_frame(self, rgb_array):
        """Called from the detector thread – schedule a UI update."""
        try:
            self.after(0, self._update_video, rgb_array)
        except:
            pass

    def _update_video(self, rgb_array):
        try:
            img = Image.fromarray(rgb_array)
            # Fit to label size
            lw = max(self._video_label.winfo_width(), 320)
            lh = max(self._video_label.winfo_height(), 240)
            img.thumbnail((lw, lh), Image.LANCZOS)
            self._video_photo = ImageTk.PhotoImage(img)
            self._video_label.config(image=self._video_photo)
        except:
            pass

    # ── Helpers ──
    def _set_status(self, msg):
        self.after(0, lambda: self._status_var.set(msg))

    def _on_close(self):
        if self._live_detector:
            self._live_detector.stop()
        self.destroy()
        sys.exit(0)


# ═════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    app = NorthStarApp()
    app.mainloop()
