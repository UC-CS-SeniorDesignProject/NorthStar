"""
NorthStar OCR Application
Two modes:
  1. Report Mode  - Upload an image or PDF, select models per category,
                    generate reports, export, and A/B compare with diff scoring
  2. Live Detection Mode - Real-time camera feed with YOLO + OCR + BLIP
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
import json
import shutil
import numpy as np
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from difflib import SequenceMatcher, unified_diff
from datetime import datetime
from PIL import Image, ImageTk
from ultralytics import YOLO
from transformers import (
    BlipProcessor, BlipForConditionalGeneration,
    GitProcessor, GitForCausalLM,
    VisionEncoderDecoderModel, ViTImageProcessor, AutoTokenizer,
    TrOCRProcessor,
)
import fitz  # PyMuPDF

# ─── Paths ────────────────────────────────────────────────────────────────────
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ─── Configuration ────────────────────────────────────────────────────────────
OCR_TRIGGERS = [
    "book", "traffic light", "stop sign", "parking meter",
    "remote", "cell phone", "laptop", "monitor", "tv",
    "clock", "sign", "screen", "menu", "bottle", "cup",
]
OCR_COOLDOWN = 1.0
LOCK_TIMEOUT = 3.0
CENTER_BIAS_WEIGHT = 2.0


# ═════════════════════════════════════════════════════════════════════════════
#  MODEL REGISTRY
# ═════════════════════════════════════════════════════════════════════════════

MODEL_REGISTRY = {
    "caption": {
        "label": "Scene Captioning",
        "models": {
            "blip-base": {
                "name": "BLIP Base",
                "hf_id": "Salesforce/blip-image-captioning-base",
                "size": "~990 MB",
                "speed": "Medium",
                "desc": "Balanced captioning model (default)",
            },
            "blip-large": {
                "name": "BLIP Large",
                "hf_id": "Salesforce/blip-image-captioning-large",
                "size": "~1.8 GB",
                "speed": "Slow",
                "desc": "More detailed captions, higher accuracy",
            },
            "git-base": {
                "name": "GIT Base (COCO)",
                "hf_id": "microsoft/git-base-coco",
                "size": "~700 MB",
                "speed": "Fast",
                "desc": "Microsoft GenerativeImage2Text, lightweight",
            },
            "vit-gpt2": {
                "name": "ViT-GPT2",
                "hf_id": "nlpconnect/vit-gpt2-image-captioning",
                "size": "~500 MB",
                "speed": "Fastest",
                "desc": "Smallest and fastest captioning model",
            },
        },
        "default": "blip-base",
    },
    "detection": {
        "label": "Object Detection",
        "models": {
            "yolov8n": {
                "name": "YOLOv8 Nano",
                "file": "yolov8n.pt",
                "size": "~6 MB",
                "speed": "Fastest",
                "desc": "Ultra-light, lowest accuracy",
            },
            "yolov8s": {
                "name": "YOLOv8 Small",
                "file": "yolov8s.pt",
                "size": "~22 MB",
                "speed": "Fast",
                "desc": "Good balance of speed and accuracy (default)",
            },
            "yolov8m": {
                "name": "YOLOv8 Medium",
                "file": "yolov8m.pt",
                "size": "~52 MB",
                "speed": "Medium",
                "desc": "Higher accuracy, moderate speed",
            },
            "yolov8l": {
                "name": "YOLOv8 Large",
                "file": "yolov8l.pt",
                "size": "~87 MB",
                "speed": "Slow",
                "desc": "High accuracy, slower inference",
            },
            "yolov8x": {
                "name": "YOLOv8 XLarge",
                "file": "yolov8x.pt",
                "size": "~136 MB",
                "speed": "Slowest",
                "desc": "Maximum accuracy, heaviest model",
            },
        },
        "default": "yolov8s",
    },
    "ocr": {
        "label": "Text Recognition (OCR)",
        "models": {
            "easyocr": {
                "name": "EasyOCR",
                "size": "~100 MB",
                "speed": "Medium",
                "desc": "General-purpose OCR, good all-rounder (default)",
            },
            "tesseract": {
                "name": "Tesseract OCR",
                "size": "~30 MB",
                "speed": "Fast",
                "desc": "Classic OCR engine, needs Tesseract installed",
            },
            "trocr-base": {
                "name": "TrOCR Base (Printed)",
                "hf_id": "microsoft/trocr-base-printed",
                "size": "~1.3 GB",
                "speed": "Slow",
                "desc": "Transformer OCR, best on clean printed text",
            },
        },
        "default": "easyocr",
    },
}


def check_model_installed(category, model_key):
    """Check if a model is available / installed."""
    info = MODEL_REGISTRY[category]["models"][model_key]

    if category == "detection":
        # YOLO: check .pt file exists locally (ultralytics auto-downloads)
        pt_path = os.path.join(BASE_DIR, info["file"])
        if os.path.isfile(pt_path):
            return True, "Local .pt file found"
        return True, "Will auto-download on first use"

    if model_key == "easyocr":
        try:
            import easyocr as _
            return True, "Package installed"
        except ImportError:
            return False, "easyocr not installed"

    if model_key == "tesseract":
        try:
            import pytesseract
            tess_path = shutil.which("tesseract")
            if tess_path:
                return True, f"Binary: {tess_path}"
            return False, "pytesseract installed but tesseract binary not found"
        except ImportError:
            return False, "pytesseract not installed"

    # HuggingFace models: check cache
    hf_id = info.get("hf_id", "")
    if hf_id:
        try:
            from huggingface_hub import scan_cache_dir
            cache = scan_cache_dir()
            for repo in cache.repos:
                if repo.repo_id == hf_id:
                    return True, "Cached locally"
        except Exception:
            pass
        return True, "Will download on first use"

    return True, "Available"


# ─── Lazy model loading ──────────────────────────────────────────────────────
_models = {}
_model_lock = threading.Lock()


def _load_model(key, loader_fn):
    with _model_lock:
        if key not in _models:
            _models[key] = loader_fn()
    return _models[key]


def get_caption_model(model_key):
    info = MODEL_REGISTRY["caption"]["models"][model_key]
    hf_id = info["hf_id"]

    if model_key.startswith("blip"):
        def load():
            proc = BlipProcessor.from_pretrained(hf_id)
            m = BlipForConditionalGeneration.from_pretrained(hf_id)
            return ("blip", proc, m)
        return _load_model(f"caption:{model_key}", load)

    if model_key == "git-base":
        def load():
            proc = GitProcessor.from_pretrained(hf_id)
            m = GitForCausalLM.from_pretrained(hf_id)
            return ("git", proc, m)
        return _load_model(f"caption:{model_key}", load)

    if model_key == "vit-gpt2":
        def load():
            m = VisionEncoderDecoderModel.from_pretrained(hf_id)
            feat = ViTImageProcessor.from_pretrained(hf_id)
            tok = AutoTokenizer.from_pretrained(hf_id)
            return ("vit-gpt2", feat, tok, m)
        return _load_model(f"caption:{model_key}", load)


def get_detection_model(model_key):
    info = MODEL_REGISTRY["detection"]["models"][model_key]
    pt_file = info["file"]
    pt_path = os.path.join(BASE_DIR, pt_file)
    # If not local, ultralytics will auto-download by name
    load_target = pt_path if os.path.isfile(pt_path) else pt_file

    def load():
        return YOLO(load_target)
    return _load_model(f"detection:{model_key}", load)


def get_ocr_model(model_key):
    if model_key == "easyocr":
        def load():
            return ("easyocr", easyocr.Reader(["en"], gpu=False))
        return _load_model("ocr:easyocr", load)

    if model_key == "tesseract":
        def load():
            import pytesseract
            return ("tesseract", pytesseract)
        return _load_model("ocr:tesseract", load)

    if model_key == "trocr-base":
        info = MODEL_REGISTRY["ocr"]["models"][model_key]
        def load():
            proc = TrOCRProcessor.from_pretrained(info["hf_id"])
            m = VisionEncoderDecoderModel.from_pretrained(info["hf_id"])
            return ("trocr", proc, m)
        return _load_model("ocr:trocr-base", load)


# ═════════════════════════════════════════════════════════════════════════════
#  REPORT MODE LOGIC
# ═════════════════════════════════════════════════════════════════════════════

def load_images_from_file(path):
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


def run_caption(pil_image, model_key):
    """Run a captioning model. Returns string."""
    loaded = get_caption_model(model_key)
    kind = loaded[0]

    if kind == "blip":
        _, proc, model = loaded
        inputs = proc(images=pil_image, return_tensors="pt")
        with torch.no_grad():
            out = model.generate(**inputs, max_new_tokens=50)
        return proc.decode(out[0], skip_special_tokens=True).capitalize()

    if kind == "git":
        _, proc, model = loaded
        inputs = proc(images=pil_image, return_tensors="pt")
        with torch.no_grad():
            out = model.generate(**inputs, max_new_tokens=50)
        return proc.batch_decode(out, skip_special_tokens=True)[0].capitalize()

    if kind == "vit-gpt2":
        _, feat, tok, model = loaded
        pixel = feat(images=pil_image, return_tensors="pt").pixel_values
        with torch.no_grad():
            out = model.generate(pixel, max_new_tokens=50)
        return tok.decode(out[0], skip_special_tokens=True).capitalize()


def run_detection(cv_img, model_key):
    """Run an object detection model. Returns string."""
    yolo = get_detection_model(model_key)
    det = yolo(cv_img, verbose=False)
    lines = []
    for r in det:
        for box in r.boxes:
            label = yolo.names[int(box.cls[0])]
            conf = float(box.conf[0])
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            lines.append(f"  {label} ({conf:.0%})  [{x1},{y1},{x2},{y2}]")
    return "\n".join(lines) if lines else "No objects detected."


def run_ocr(cv_img, pil_image, model_key):
    """Run an OCR model. Returns string."""
    loaded = get_ocr_model(model_key)
    kind = loaded[0]

    if kind == "easyocr":
        reader = loaded[1]
        gray = cv2.cvtColor(cv_img, cv2.COLOR_BGR2GRAY)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        enhanced = clahe.apply(gray)
        results = reader.readtext(enhanced, detail=1, paragraph=False)
        lines = [f"  [{conf:.0%}] {text}" for _, text, conf in results]
        return "\n".join(lines) if lines else "No text detected."

    if kind == "tesseract":
        pytesseract = loaded[1]
        gray = cv2.cvtColor(cv_img, cv2.COLOR_BGR2GRAY)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        enhanced = clahe.apply(gray)
        text = pytesseract.image_to_string(enhanced).strip()
        return text if text else "No text detected."

    if kind == "trocr":
        _, proc, model = loaded
        # TrOCR works best on cropped text lines; run on full image as-is
        pixel = proc(images=pil_image, return_tensors="pt").pixel_values
        with torch.no_grad():
            out = model.generate(pixel, max_new_tokens=200)
        text = proc.batch_decode(out, skip_special_tokens=True)[0].strip()
        return text if text else "No text detected."


def run_report(pil_image, model_choices, enabled_categories):
    """
    Run selected models on a PIL image.
    model_choices: {category: model_key}
    enabled_categories: set of category keys to run
    Returns dict of {display_name: output}
    """
    cv_img = cv2.cvtColor(np.array(pil_image), cv2.COLOR_RGB2BGR)
    results = {}

    if "caption" in enabled_categories:
        key = model_choices.get("caption", "blip-base")
        name = MODEL_REGISTRY["caption"]["models"][key]["name"]
        try:
            results[f"Caption ({name})"] = run_caption(pil_image, key)
        except Exception as e:
            results[f"Caption ({name})"] = f"Error: {e}"

    if "detection" in enabled_categories:
        key = model_choices.get("detection", "yolov8s")
        name = MODEL_REGISTRY["detection"]["models"][key]["name"]
        try:
            results[f"Detection ({name})"] = run_detection(cv_img, key)
        except Exception as e:
            results[f"Detection ({name})"] = f"Error: {e}"

    if "ocr" in enabled_categories:
        key = model_choices.get("ocr", "easyocr")
        name = MODEL_REGISTRY["ocr"]["models"][key]["name"]
        try:
            results[f"OCR ({name})"] = run_ocr(cv_img, pil_image, key)
        except Exception as e:
            results[f"OCR ({name})"] = f"Error: {e}"

    return results


# ═════════════════════════════════════════════════════════════════════════════
#  COMPARISON / DIFF LOGIC
# ═════════════════════════════════════════════════════════════════════════════

def similarity_score(a, b):
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio()


def compute_diff(text_a, text_b):
    lines_a = text_a.splitlines(keepends=True)
    lines_b = text_b.splitlines(keepends=True)
    return "".join(unified_diff(lines_a, lines_b, fromfile="Run A",
                                tofile="Run B", lineterm=""))


def compare_runs(run_a, run_b):
    lines = []
    all_scores = []

    pages_a = {label: data for label, data in run_a}
    pages_b = {label: data for label, data in run_b}
    all_pages = list(dict.fromkeys(
        [l for l, _ in run_a] + [l for l, _ in run_b]
    ))

    for page in all_pages:
        lines.append(f"{'=' * 60}")
        lines.append(f"  {page}")
        lines.append(f"{'=' * 60}")

        data_a = pages_a.get(page, {})
        data_b = pages_b.get(page, {})
        all_models = list(dict.fromkeys(
            list(data_a.keys()) + list(data_b.keys())
        ))

        for model in all_models:
            out_a = data_a.get(model, "(not run)")
            out_b = data_b.get(model, "(not run)")
            score = similarity_score(out_a, out_b)
            all_scores.append(score)

            lines.append(f"\n  [{model}]  Similarity: {score:.0%}")
            lines.append(f"  {'_' * 50}")

            if out_a == out_b:
                lines.append("  IDENTICAL")
                lines.append(f"  {out_a}")
            else:
                diff = compute_diff(out_a, out_b)
                if diff.strip():
                    for dl in diff.splitlines():
                        if dl.startswith("+") and not dl.startswith("+++"):
                            lines.append(f"  [B+] {dl}")
                        elif dl.startswith("-") and not dl.startswith("---"):
                            lines.append(f"  [A-] {dl}")
                        else:
                            lines.append(f"  {dl}")
                else:
                    lines.append(f"  Run A: {out_a}")
                    lines.append(f"  Run B: {out_b}")
        lines.append("")

    overall = sum(all_scores) / len(all_scores) if all_scores else 0.0
    lines.append(f"{'=' * 60}")
    lines.append(f"  OVERALL SIMILARITY SCORE: {overall:.1%}")
    lines.append(f"  Models compared: {len(all_scores)}")
    lines.append(f"{'=' * 60}")

    return "\n".join(lines), overall


# ═════════════════════════════════════════════════════════════════════════════
#  LIVE DETECTION (uses default models)
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
    def __init__(self, frame_callback, status_callback, camera_index=0):
        self.frame_cb = frame_callback
        self.status_cb = status_callback
        self.camera_index = camera_index
        self.running = False
        self._thread = None

        self._ocr_queue = queue.Queue(maxsize=1)
        self._ocr_text = ""
        self._ocr_lock = threading.Lock()
        self._ocr_thread = threading.Thread(target=self._ocr_loop, daemon=True)
        self._ocr_thread.start()

        self._scene_desc = "Analyzing scene..."
        self._scene_lock = threading.Lock()

        self.smoother = SmoothingFilter()
        self.locked_label = None
        self.locked_box = None
        self.last_seen_time = 0
        self.last_ocr_time = 0

    def _ocr_loop(self):
        _, reader = get_ocr_model("easyocr")
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

    def _analyze_scene(self, frame):
        try:
            _, proc, model = get_caption_model("blip-base")
            pil = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            inputs = proc(images=pil, return_tensors="pt")
            with torch.no_grad():
                out = model.generate(**inputs, max_new_tokens=30)
            desc = proc.decode(out[0], skip_special_tokens=True).capitalize()
            with self._scene_lock:
                self._scene_desc = desc
        except:
            pass

    @staticmethod
    def _focus_score(box, w, h):
        x1, y1, x2, y2 = box
        area_score = ((x2 - x1) * (y2 - y1)) / (w * h)
        bcx, bcy = (x1 + x2) / 2, (y1 + y2) / 2
        dist = math.sqrt((bcx - w / 2) ** 2 + (bcy - h / 2) ** 2)
        max_dist = math.sqrt((w / 2) ** 2 + (h / 2) ** 2)
        return area_score + (1.0 - dist / max_dist) * CENTER_BIAS_WEIGHT

    def start(self):
        if self.running:
            return
        self.running = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self.running = False

    def _run(self):
        yolo = get_detection_model("yolov8s")
        cap = cv2.VideoCapture(self.camera_index)
        cap.set(cv2.CAP_PROP_FPS, 30)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

        if not cap.isOpened():
            self.status_cb("ERROR: Could not open camera.")
            self.running = False
            return

        self.status_cb("Live detection running -- press Stop to end.")
        scene_timer = 0

        while self.running:
            ret, frame = cap.read()
            if not ret:
                break
            h, w = frame.shape[:2]
            display = frame.copy()
            cx, cy = w // 2, h // 2
            cv2.line(display, (cx - 20, cy), (cx + 20, cy), (200, 200, 200), 1)
            cv2.line(display, (cx, cy - 20), (cx, cy + 20), (200, 200, 200), 1)

            results = yolo(frame, verbose=False, stream=True)
            candidates = []
            for r in results:
                for box in r.boxes:
                    label = yolo.names[int(box.cls[0])]
                    if float(box.conf[0]) < 0.5:
                        continue
                    if label in OCR_TRIGGERS:
                        coords = tuple(map(int, box.xyxy[0]))
                        candidates.append(
                            (label, coords, self._focus_score(coords, w, h)))

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

            for lbl, bx, _ in candidates:
                if lbl != self.locked_label:
                    x1, y1, x2, y2 = bx
                    cv2.rectangle(display, (x1, y1), (x2, y2), (100, 50, 0), 1)

            if best and self.locked_label:
                lbl, raw_box, _ = best
                self.locked_box = self.smoother.smooth(lbl, raw_box)
                x1, y1, x2, y2 = self.locked_box
                obj_cx, obj_cy = (x1 + x2) // 2, (y1 + y2) // 2
                cv2.line(display, (cx, cy), (obj_cx, obj_cy), (0, 255, 0), 2)
                cv2.rectangle(display, (x1, y1), (x2, y2), (0, 255, 0), 3)
                cv2.putText(display, f"LOCKED: {lbl}", (x1, y1 - 15),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
                if time.time() - self.last_ocr_time > OCR_COOLDOWN:
                    roi = frame[max(0, y1-10):min(h, y2+10),
                                max(0, x1-10):min(w, x2+10)]
                    self._request_ocr(roi.copy())
                    self.last_ocr_time = time.time()

            with self._ocr_lock:
                text = self._ocr_text
            if self.locked_label and len(text) > 2:
                cv2.rectangle(display, (0, h-80), (w, h), (0, 0, 0), -1)
                cv2.putText(display, f"READING: {text}", (30, h-30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)

            if time.time() - scene_timer > 5:
                threading.Thread(target=self._analyze_scene,
                                 args=(frame.copy(),), daemon=True).start()
                scene_timer = time.time()
            with self._scene_lock:
                desc = self._scene_desc
            cv2.rectangle(display, (0, 0), (w, 40), (0, 0, 0), -1)
            cv2.putText(display, f"SCENE: {desc}", (10, 30),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 255), 1)

            self.frame_cb(cv2.cvtColor(display, cv2.COLOR_BGR2RGB))

        cap.release()
        self.running = False
        self.status_cb("Live detection stopped.")


# ═════════════════════════════════════════════════════════════════════════════
#  MODEL SELECTOR POPUP
# ═════════════════════════════════════════════════════════════════════════════

class ModelSelectorDialog(tk.Toplevel):
    """Popup that shows all model categories with radio-button selection."""

    BG = "#1e1e2e"
    FG = "#cdd6f4"
    BG2 = "#181825"
    ACCENT = "#89b4fa"
    GREEN = "#a6e3a1"
    YELLOW = "#f9e2af"
    DIM = "#6c7086"

    def __init__(self, parent, current_choices):
        super().__init__(parent)
        self.title("Model Selector")
        self.configure(bg=self.BG)
        self.resizable(False, False)
        self.grab_set()

        self.result = None  # will be set if OK pressed
        self._vars = {}  # category -> StringVar

        # Build one section per category
        for cat_key, cat_info in MODEL_REGISTRY.items():
            self._build_category(cat_key, cat_info,
                                 current_choices.get(cat_key, cat_info["default"]))

        # OK / Cancel
        btn_frame = tk.Frame(self, bg=self.BG)
        btn_frame.pack(fill="x", padx=16, pady=(4, 16))
        ttk.Button(btn_frame, text="Apply", command=self._on_ok).pack(
            side="right", padx=4)
        ttk.Button(btn_frame, text="Cancel", command=self.destroy).pack(
            side="right", padx=4)

        # Center on parent
        self.update_idletasks()
        pw, ph = parent.winfo_width(), parent.winfo_height()
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        w, h = self.winfo_width(), self.winfo_height()
        self.geometry(f"+{px + (pw - w) // 2}+{py + (ph - h) // 2}")

    def _build_category(self, cat_key, cat_info, current):
        outer = tk.LabelFrame(
            self, text=f"  {cat_info['label']}  ",
            bg=self.BG, fg=self.ACCENT,
            font=("Segoe UI", 11, "bold"),
            padx=12, pady=8,
        )
        outer.pack(fill="x", padx=16, pady=(12, 0))

        var = tk.StringVar(value=current)
        self._vars[cat_key] = var

        for mk, mi in cat_info["models"].items():
            installed, status_msg = check_model_installed(cat_key, mk)

            row = tk.Frame(outer, bg=self.BG)
            row.pack(fill="x", pady=2)

            rb = tk.Radiobutton(
                row, variable=var, value=mk,
                bg=self.BG, fg=self.FG, selectcolor=self.BG2,
                activebackground=self.BG, activeforeground=self.FG,
                font=("Segoe UI", 10),
                text="",
                indicatoron=True,
            )
            rb.pack(side="left")

            # Name
            tk.Label(row, text=mi["name"], bg=self.BG, fg=self.FG,
                     font=("Segoe UI", 10, "bold"), width=22,
                     anchor="w").pack(side="left")

            # Size pill
            tk.Label(row, text=mi["size"], bg=self.BG2, fg=self.YELLOW,
                     font=("Consolas", 9), padx=6, pady=1).pack(
                side="left", padx=(0, 6))

            # Speed pill
            speed = mi["speed"]
            speed_color = (self.GREEN if speed in ("Fast", "Fastest")
                           else self.YELLOW if speed == "Medium"
                           else "#f38ba8")
            tk.Label(row, text=speed, bg=self.BG2, fg=speed_color,
                     font=("Consolas", 9), padx=6, pady=1).pack(
                side="left", padx=(0, 6))

            # Installed status
            status_color = self.GREEN if installed else "#f38ba8"
            tk.Label(row, text=status_msg, bg=self.BG, fg=status_color,
                     font=("Segoe UI", 8)).pack(side="left", padx=(0, 4))

            # Description (dim)
            tk.Label(row, text=mi["desc"], bg=self.BG, fg=self.DIM,
                     font=("Segoe UI", 8), anchor="w").pack(
                side="left", fill="x", expand=True)

    def _on_ok(self):
        self.result = {cat: var.get() for cat, var in self._vars.items()}
        self.destroy()


# ═════════════════════════════════════════════════════════════════════════════
#  MAIN UI
# ═════════════════════════════════════════════════════════════════════════════

class NorthStarApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("NorthStar OCR")
        self.geometry("1200x800")
        self.minsize(1000, 650)
        self.configure(bg="#1e1e2e")
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        self._style_setup()

        # ── State ──
        self._loaded_images = []
        self._run_a_results = None
        self._run_a_choices = {}
        self._run_a_enabled = set()
        self._run_b_results = None
        self._last_report_text = ""
        self._live_detector = None

        # Model choices (one per category)
        self._model_choices = {
            cat: info["default"] for cat, info in MODEL_REGISTRY.items()
        }

        # ── Header ──
        header = tk.Frame(self, bg="#181825", height=50)
        header.pack(fill="x")
        header.pack_propagate(False)
        tk.Label(header, text="NORTHSTAR OCR", font=("Segoe UI", 16, "bold"),
                 bg="#181825", fg="#cdd6f4").pack(side="left", padx=16)

        self._mode_var = tk.StringVar(value="report")
        mode_frame = tk.Frame(header, bg="#181825")
        mode_frame.pack(side="right", padx=16)
        for text, val in [("Report Mode", "report"), ("Live Detection", "live")]:
            ttk.Radiobutton(mode_frame, text=text, variable=self._mode_var,
                            value=val, command=self._switch_mode,
                            style="Mode.TRadiobutton").pack(side="left", padx=8)

        # ── Main body ──
        self._body = tk.Frame(self, bg="#1e1e2e")
        self._body.pack(fill="both", expand=True)
        self._report_frame = self._build_report_frame(self._body)
        self._live_frame = self._build_live_frame(self._body)
        self._report_frame.place(relx=0, rely=0, relwidth=1, relheight=1)
        self._live_frame.place(relx=0, rely=0, relwidth=1, relheight=1)

        # ── Status bar ──
        self._status_var = tk.StringVar(value="Ready")
        tk.Label(self, textvariable=self._status_var, anchor="w",
                 bg="#11111b", fg="#a6adc8", font=("Segoe UI", 9),
                 padx=8).pack(fill="x", side="bottom")

        self._switch_mode()

    def _style_setup(self):
        s = ttk.Style(self)
        s.theme_use("clam")
        s.configure("Mode.TRadiobutton", background="#181825",
                    foreground="#cdd6f4", font=("Segoe UI", 11))
        s.map("Mode.TRadiobutton",
              background=[("active", "#313244")],
              foreground=[("active", "#f5c2e7")])
        s.configure("Accent.TButton", font=("Segoe UI", 10, "bold"), padding=6)
        s.configure("Small.TButton", font=("Segoe UI", 9), padding=4)
        s.configure("RunA.TButton", font=("Segoe UI", 9, "bold"),
                    padding=4, foreground="#a6e3a1")
        s.configure("RunB.TButton", font=("Segoe UI", 9, "bold"),
                    padding=4, foreground="#89b4fa")
        s.configure("Model.TCheckbutton", background="#1e1e2e",
                    foreground="#cdd6f4", font=("Segoe UI", 10))
        s.map("Model.TCheckbutton", background=[("active", "#313244")])

    # ══════════════════════════════════════════════════════════════════════
    #  REPORT MODE UI
    # ══════════════════════════════════════════════════════════════════════
    def _build_report_frame(self, parent):
        frame = tk.Frame(parent, bg="#1e1e2e")

        # ── Left panel ──
        left = tk.Frame(frame, bg="#1e1e2e", width=380)
        left.pack(side="left", fill="y", padx=(12, 4), pady=12)
        left.pack_propagate(False)

        ttk.Button(left, text="Browse File...",
                   command=self._open_file, style="Accent.TButton").pack(
            fill="x", pady=(0, 6))

        # Docs listing
        tk.Label(left, text="docs/", font=("Segoe UI", 10, "bold"),
                 bg="#1e1e2e", fg="#a6adc8", anchor="w").pack(
            fill="x", pady=(2, 2))
        list_frame = tk.Frame(left, bg="#11111b")
        list_frame.pack(fill="x")
        self._docs_listbox = tk.Listbox(
            list_frame, bg="#11111b", fg="#cdd6f4",
            selectbackground="#45475a", selectforeground="#f5c2e7",
            font=("Consolas", 10), relief="flat", height=5,
            activestyle="none", highlightthickness=0, bd=0)
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
        self._file_label.pack(fill="x", pady=(4, 0))

        # ── Category enable checkboxes + model selector button ──
        model_header = tk.Frame(left, bg="#1e1e2e")
        model_header.pack(fill="x", pady=(10, 2))
        tk.Label(model_header, text="Categories", font=("Segoe UI", 10, "bold"),
                 bg="#1e1e2e", fg="#a6adc8", anchor="w").pack(side="left")
        ttk.Button(model_header, text="Select Models...",
                   command=self._open_model_selector,
                   style="Small.TButton").pack(side="right")

        self._cat_vars = {}
        self._cat_labels = {}
        for cat_key, cat_info in MODEL_REGISTRY.items():
            row = tk.Frame(left, bg="#1e1e2e")
            row.pack(fill="x", padx=4, pady=1)
            var = tk.BooleanVar(value=True)
            self._cat_vars[cat_key] = var
            ttk.Checkbutton(row, text=cat_info["label"], variable=var,
                            style="Model.TCheckbutton").pack(
                side="left", anchor="w")
            lbl = tk.Label(
                row, bg="#1e1e2e", fg="#6c7086", font=("Segoe UI", 8),
                text=MODEL_REGISTRY[cat_key]["models"][
                    self._model_choices[cat_key]]["name"],
                anchor="e")
            lbl.pack(side="right")
            self._cat_labels[cat_key] = lbl

        # ── Image preview ──
        self._preview_canvas = tk.Canvas(left, bg="#11111b",
                                         highlightthickness=0)
        self._preview_canvas.pack(fill="both", expand=True, pady=(10, 0))
        self._preview_photo = None

        # ── Right panel ──
        right = tk.Frame(frame, bg="#1e1e2e")
        right.pack(side="left", fill="both", expand=True, padx=(4, 12),
                   pady=12)

        btn_bar = tk.Frame(right, bg="#1e1e2e")
        btn_bar.pack(fill="x")
        tk.Label(btn_bar, text="Analysis Results",
                 font=("Segoe UI", 13, "bold"), bg="#1e1e2e",
                 fg="#cdd6f4").pack(side="left")

        self._export_btn = ttk.Button(btn_bar, text="Export",
                                      command=self._export_report,
                                      style="Small.TButton")
        self._export_btn.pack(side="right", padx=2)
        self._compare_btn = ttk.Button(btn_bar, text="Run B + Compare",
                                       command=self._run_b_compare,
                                       style="RunB.TButton")
        self._compare_btn.pack(side="right", padx=2)
        self._compare_btn.config(state="disabled")
        self._save_a_btn = ttk.Button(btn_bar, text="Save as Run A",
                                      command=self._save_run_a,
                                      style="RunA.TButton")
        self._save_a_btn.pack(side="right", padx=2)
        self._save_a_btn.config(state="disabled")
        self._run_btn = ttk.Button(btn_bar, text="Run Analysis",
                                   command=self._run_report,
                                   style="Accent.TButton")
        self._run_btn.pack(side="right", padx=(2, 8))
        self._run_a_label = tk.Label(btn_bar, text="", bg="#1e1e2e",
                                     fg="#a6e3a1", font=("Segoe UI", 9))
        self._run_a_label.pack(side="right", padx=4)

        # Results text
        self._results_text = tk.Text(right, wrap="word", bg="#11111b",
                                     fg="#cdd6f4", font=("Consolas", 10),
                                     insertbackground="#cdd6f4",
                                     relief="flat", padx=10, pady=10)
        self._results_text.pack(fill="both", expand=True, pady=(8, 0))
        self._results_text.config(state="disabled")

        for tag, cfg in {
            "heading":    {"font": ("Segoe UI", 12, "bold"), "foreground": "#f5c2e7", "spacing1": 12, "spacing3": 4},
            "subheading": {"font": ("Segoe UI", 10, "bold"), "foreground": "#89b4fa", "spacing1": 8, "spacing3": 2},
            "body":       {"font": ("Consolas", 10), "foreground": "#cdd6f4"},
            "separator":  {"foreground": "#45475a"},
            "diff_add":   {"font": ("Consolas", 10), "foreground": "#a6e3a1"},
            "diff_rem":   {"font": ("Consolas", 10), "foreground": "#f38ba8"},
            "diff_hdr":   {"font": ("Consolas", 10), "foreground": "#89b4fa"},
            "score_good": {"font": ("Segoe UI", 12, "bold"), "foreground": "#a6e3a1", "spacing1": 8},
            "score_mid":  {"font": ("Segoe UI", 12, "bold"), "foreground": "#f9e2af", "spacing1": 8},
            "score_bad":  {"font": ("Segoe UI", 12, "bold"), "foreground": "#f38ba8", "spacing1": 8},
            "identical":  {"font": ("Consolas", 10), "foreground": "#a6e3a1"},
        }.items():
            self._results_text.tag_configure(tag, **cfg)

        return frame

    # ══════════════════════════════════════════════════════════════════════
    #  LIVE MODE UI
    # ══════════════════════════════════════════════════════════════════════
    def _build_live_frame(self, parent):
        frame = tk.Frame(parent, bg="#1e1e2e")
        ctrl = tk.Frame(frame, bg="#1e1e2e")
        ctrl.pack(fill="x", padx=12, pady=(12, 4))
        self._cam_var = tk.StringVar(value="0")
        tk.Label(ctrl, text="Camera Index:", bg="#1e1e2e", fg="#cdd6f4",
                 font=("Segoe UI", 10)).pack(side="left")
        ttk.Entry(ctrl, textvariable=self._cam_var, width=4).pack(
            side="left", padx=(4, 16))
        self._start_btn = ttk.Button(ctrl, text="Start",
                                     command=self._start_live,
                                     style="Accent.TButton")
        self._start_btn.pack(side="left", padx=4)
        self._stop_btn = ttk.Button(ctrl, text="Stop",
                                    command=self._stop_live,
                                    style="Accent.TButton")
        self._stop_btn.pack(side="left", padx=4)
        self._stop_btn.config(state="disabled")
        self._video_label = tk.Label(frame, bg="#11111b")
        self._video_label.pack(fill="both", expand=True, padx=12, pady=(4, 12))
        self._video_photo = None
        return frame

    # ══════════════════════════════════════════════════════════════════════
    #  MODE / DOCS / FILE
    # ══════════════════════════════════════════════════════════════════════
    def _switch_mode(self):
        if self._mode_var.get() == "report":
            self._report_frame.lift()
            self._stop_live()
        else:
            self._live_frame.lift()

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
        if sel:
            self._load_file(self._docs_files[sel[0]])

    def _open_file(self):
        path = filedialog.askopenfilename(
            filetypes=[("Images & PDFs",
                        "*.png *.jpg *.jpeg *.bmp *.tiff *.tif *.pdf"),
                       ("All files", "*.*")])
        if path:
            self._load_file(path)

    def _load_file(self, path):
        self._status_var.set(f"Loading {os.path.basename(path)}...")
        self.update_idletasks()
        try:
            self._loaded_images = load_images_from_file(path)
        except Exception as e:
            messagebox.showerror("Error", str(e))
            return
        self._file_label.config(
            text=f"{os.path.basename(path)}  "
                 f"({len(self._loaded_images)} page(s))")
        self._show_preview(self._loaded_images[0][1])
        self._status_var.set("File loaded. Select models and run analysis.")
        self._run_a_results = None
        self._run_a_choices = {}
        self._run_a_enabled = set()
        self._run_a_label.config(text="")
        self._save_a_btn.config(state="disabled")
        self._compare_btn.config(state="disabled")
        self._clear_results()

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

    def _clear_results(self):
        self._results_text.config(state="normal")
        self._results_text.delete("1.0", "end")
        self._results_text.config(state="disabled")
        self._last_report_text = ""

    # ══════════════════════════════════════════════════════════════════════
    #  MODEL SELECTOR
    # ══════════════════════════════════════════════════════════════════════
    def _open_model_selector(self):
        dlg = ModelSelectorDialog(self, self._model_choices)
        self.wait_window(dlg)
        if dlg.result:
            self._model_choices = dlg.result
            # Update the labels next to each category checkbox
            for cat_key, lbl in self._cat_labels.items():
                mk = self._model_choices[cat_key]
                name = MODEL_REGISTRY[cat_key]["models"][mk]["name"]
                lbl.config(text=name)
            self._status_var.set("Model selection updated.")

    def _get_enabled_categories(self):
        return {k for k, v in self._cat_vars.items() if v.get()}

    # ══════════════════════════════════════════════════════════════════════
    #  RUN ANALYSIS
    # ══════════════════════════════════════════════════════════════════════
    def _run_report(self):
        if not self._loaded_images:
            messagebox.showinfo("No file", "Open an image or PDF first.")
            return
        enabled = self._get_enabled_categories()
        if not enabled:
            messagebox.showinfo("No categories",
                                "Enable at least one category.")
            return
        self._run_btn.config(state="disabled")
        self._status_var.set("Running analysis...")
        self.update_idletasks()
        choices = dict(self._model_choices)
        threading.Thread(target=self._report_worker,
                         args=(choices, enabled, False),
                         daemon=True).start()

    def _report_worker(self, choices, enabled, is_run_b):
        all_results = []
        total = len(self._loaded_images)
        for i, (label, pil_img) in enumerate(self._loaded_images):
            tag = "Run B" if is_run_b else "Run"
            self._set_status(f"{tag}: Processing {label} ({i+1}/{total})...")
            results = run_report(pil_img, choices, enabled)
            all_results.append((label, results))
        if is_run_b:
            self.after(0, self._finish_run_b, all_results)
        else:
            self.after(0, self._display_results, all_results)

    def _display_results(self, all_results):
        tw = self._results_text
        tw.config(state="normal")
        tw.delete("1.0", "end")

        report_lines = []
        enabled = self._get_enabled_categories()
        model_names = []
        for cat in enabled:
            mk = self._model_choices[cat]
            model_names.append(MODEL_REGISTRY[cat]["models"][mk]["name"])
        report_lines.append(f"Models: {', '.join(model_names)}")
        report_lines.append(
            f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        report_lines.append("")

        for page_label, results in all_results:
            tw.insert("end", f"{'='*3}  {page_label}  {'='*3}\n", "heading")
            report_lines.append(f"=== {page_label} ===")
            for model_name, output in results.items():
                tw.insert("end", f"\n> {model_name}\n", "subheading")
                tw.insert("end", f"{output}\n", "body")
                report_lines.append(f"\n> {model_name}")
                report_lines.append(output)
            tw.insert("end", "\n" + "-" * 60 + "\n", "separator")
            report_lines.append("-" * 60)

        tw.config(state="disabled")
        self._last_report_text = "\n".join(report_lines)
        self._last_run_results = all_results
        self._run_btn.config(state="normal")
        self._save_a_btn.config(state="normal")
        self._status_var.set("Analysis complete.")

    # ══════════════════════════════════════════════════════════════════════
    #  RUN A / RUN B + COMPARE
    # ══════════════════════════════════════════════════════════════════════
    def _save_run_a(self):
        if not hasattr(self, "_last_run_results"):
            return
        self._run_a_results = self._last_run_results
        self._run_a_choices = dict(self._model_choices)
        self._run_a_enabled = self._get_enabled_categories()
        names = []
        for cat in self._run_a_enabled:
            mk = self._run_a_choices[cat]
            names.append(MODEL_REGISTRY[cat]["models"][mk]["name"])
        self._run_a_label.config(text=f"Run A: {', '.join(names)}")
        self._compare_btn.config(state="normal")
        self._status_var.set(
            "Run A saved. Change models and click 'Run B + Compare'.")

    def _run_b_compare(self):
        if not self._loaded_images or not self._run_a_results:
            return
        enabled = self._get_enabled_categories()
        if not enabled:
            messagebox.showinfo("No categories",
                                "Enable at least one category.")
            return
        self._compare_btn.config(state="disabled")
        self._run_btn.config(state="disabled")
        self._status_var.set("Running Run B...")
        self.update_idletasks()
        choices = dict(self._model_choices)
        threading.Thread(target=self._report_worker,
                         args=(choices, enabled, True),
                         daemon=True).start()

    def _finish_run_b(self, run_b_results):
        report_text, overall = compare_runs(
            self._run_a_results, run_b_results)

        tw = self._results_text
        tw.config(state="normal")
        tw.delete("1.0", "end")

        a_names, b_names = [], []
        for cat in self._run_a_enabled:
            mk = self._run_a_choices[cat]
            a_names.append(MODEL_REGISTRY[cat]["models"][mk]["name"])
        for cat in self._get_enabled_categories():
            mk = self._model_choices[cat]
            b_names.append(MODEL_REGISTRY[cat]["models"][mk]["name"])

        tw.insert("end", "COMPARISON REPORT\n", "heading")
        tw.insert("end", f"Run A: {', '.join(a_names)}\n", "diff_rem")
        tw.insert("end", f"Run B: {', '.join(b_names)}\n", "diff_add")
        tw.insert("end",
                  f"Generated: {datetime.now():%Y-%m-%d %H:%M:%S}\n\n", "body")

        for line in report_text.splitlines():
            s = line.strip()
            if s.startswith("OVERALL SIMILARITY SCORE:"):
                tag = ("score_good" if overall >= 0.8
                       else "score_mid" if overall >= 0.5
                       else "score_bad")
                tw.insert("end", line + "\n", tag)
            elif s.startswith("IDENTICAL"):
                tw.insert("end", line + "\n", "identical")
            elif s.startswith("[B+]") or (
                    s.startswith("+") and not s.startswith("+++")):
                tw.insert("end", line + "\n", "diff_add")
            elif s.startswith("[A-]") or (
                    s.startswith("-") and not s.startswith("---")):
                tw.insert("end", line + "\n", "diff_rem")
            elif s.startswith("@@") or s.startswith("---") or s.startswith("+++"):
                tw.insert("end", line + "\n", "diff_hdr")
            elif "Similarity:" in line:
                tw.insert("end", line + "\n", "subheading")
            elif line.startswith("="):
                tw.insert("end", line + "\n", "heading")
            else:
                tw.insert("end", line + "\n", "body")

        tw.config(state="disabled")
        self._last_report_text = (
            f"COMPARISON REPORT\n"
            f"Run A: {', '.join(a_names)}\n"
            f"Run B: {', '.join(b_names)}\n"
            f"{datetime.now():%Y-%m-%d %H:%M:%S}\n\n{report_text}")

        self._run_btn.config(state="normal")
        self._compare_btn.config(state="normal")
        self._status_var.set(
            f"Comparison complete. Overall similarity: {overall:.1%}")

    # ══════════════════════════════════════════════════════════════════════
    #  EXPORT
    # ══════════════════════════════════════════════════════════════════════
    def _export_report(self):
        if not self._last_report_text:
            messagebox.showinfo("Nothing to export", "Run an analysis first.")
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".txt",
            filetypes=[("Text file", "*.txt"), ("JSON", "*.json"),
                       ("All files", "*.*")],
            initialfile=f"northstar_report_{datetime.now():%Y%m%d_%H%M%S}")
        if not path:
            return
        ext = os.path.splitext(path)[1].lower()
        if ext == ".json":
            data = {"generated": datetime.now().isoformat(),
                    "report": self._last_report_text,
                    "model_choices": self._model_choices}
            if hasattr(self, "_last_run_results"):
                data["results"] = [{"page": l, "models": d}
                                   for l, d in self._last_run_results]
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(self._last_report_text)
        self._status_var.set(f"Exported to {os.path.basename(path)}")

    # ══════════════════════════════════════════════════════════════════════
    #  LIVE DETECTION
    # ══════════════════════════════════════════════════════════════════════
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
            camera_index=cam_idx)
        self._live_detector.start()

    def _stop_live(self):
        if self._live_detector and self._live_detector.running:
            self._live_detector.stop()
        self._start_btn.config(state="normal")
        self._stop_btn.config(state="disabled")

    def _on_live_frame(self, rgb_array):
        try:
            self.after(0, self._update_video, rgb_array)
        except:
            pass

    def _update_video(self, rgb_array):
        try:
            img = Image.fromarray(rgb_array)
            lw = max(self._video_label.winfo_width(), 320)
            lh = max(self._video_label.winfo_height(), 240)
            img.thumbnail((lw, lh), Image.LANCZOS)
            self._video_photo = ImageTk.PhotoImage(img)
            self._video_label.config(image=self._video_photo)
        except:
            pass

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
