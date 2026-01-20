import cv2
import easyocr
import threading
import time
import torch
import queue
import math
import numpy as np
from ultralytics import YOLO
from transformers import BlipProcessor, BlipForConditionalGeneration
from PIL import Image

# --- CONFIGURATION ---
OCR_TRIGGERS = [
    'book', 'traffic light', 'stop sign', 'parking meter', 
    'remote', 'cell phone', 'laptop', 'monitor', 'tv', 
    'clock', 'sign', 'screen', 'menu', 'bottle', 'cup'
]

OCR_COOLDOWN = 1.0       
LOCK_TIMEOUT = 3.0       # Hard Lock for 3 seconds
CENTER_BIAS_WEIGHT = 2.0 # How much we prefer center objects (Higher = Stronger focus)

class SmoothingFilter:
    """ Smooths jittery box coordinates """
    def __init__(self):
        self.history = {} 

    def smooth(self, label, new_box):
        if label not in self.history:
            self.history[label] = new_box
            return new_box
        
        # Heavy smoothing for reading text
        prev_box = self.history[label]
        alpha = 0.3 # 0.3 = Very smooth/slow, 0.9 = Snappy/jittery
        
        smooth_box = []
        for p, n in zip(prev_box, new_box):
            smooth_box.append(int((p * (1 - alpha)) + (n * alpha)))
            
        self.history[label] = smooth_box
        return tuple(smooth_box)

class SceneBrain:
    def __init__(self):
        print(" [Init] Loading BLIP...")
        self.processor = BlipProcessor.from_pretrained("Salesforce/blip-image-captioning-base")
        self.model = BlipForConditionalGeneration.from_pretrained("Salesforce/blip-image-captioning-base")
        self.current_description = "Analyzing scene..."
        self.lock = threading.Lock()

    def analyze(self, frame):
        try:
            pil_img = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            inputs = self.processor(images=pil_img, return_tensors="pt")
            with torch.no_grad():
                out = self.model.generate(**inputs, max_new_tokens=30)
            desc = self.processor.decode(out[0], skip_special_tokens=True)
            with self.lock:
                self.current_description = desc.capitalize()
        except: pass

class OCRWorker(threading.Thread):
    def __init__(self):
        super().__init__()
        self.daemon = True
        self.input_queue = queue.Queue(maxsize=1)
        self.latest_text = ""
        self.lock = threading.Lock()
        print(" [Init] Loading EasyOCR...")
        self.reader = easyocr.Reader(['en'], gpu=True) 

    def request_ocr(self, roi):
        if not self.input_queue.full():
            self.input_queue.put(roi)

    def run(self):
        while True:
            roi = self.input_queue.get()
            try:
                # Zoom in on small crops (Helpful for cards)
                h, w = roi.shape[:2]
                if h < 300: 
                    roi = cv2.resize(roi, (0,0), fx=1.5, fy=1.5)
                
                results = self.reader.readtext(roi, detail=0, paragraph=True)
                text = " ".join(results)
                
                with self.lock:
                    self.latest_text = text
            except: pass
            finally:
                self.input_queue.task_done()

class NorthStarFocus:
    def __init__(self):
        print(" [Init] Loading YOLOv8...")
        self.yolo = YOLO('yolov8s.pt') 
        
        self.scene_brain = SceneBrain()
        self.ocr_worker = OCRWorker()
        self.ocr_worker.start()
        self.smoother = SmoothingFilter()
        
        self.running = True
        
        # State
        self.locked_label = None 
        self.locked_box = None
        self.last_seen_time = 0
        self.last_ocr_time = 0

    def calculate_focus_score(self, box, frame_w, frame_h):
        """ Returns a score based on Size + Center Proximity """
        x1, y1, x2, y2 = box
        
        # 1. Area Score (0.0 to 1.0)
        area = (x2-x1) * (y2-y1)
        max_area = frame_w * frame_h
        area_score = area / max_area
        
        # 2. Center Score (0.0 to 1.0)
        # Calculate distance from center of box to center of screen
        box_cx = (x1 + x2) / 2
        box_cy = (y1 + y2) / 2
        screen_cx = frame_w / 2
        screen_cy = frame_h / 2
        
        dist = math.sqrt((box_cx - screen_cx)**2 + (box_cy - screen_cy)**2)
        max_dist = math.sqrt(screen_cx**2 + screen_cy**2)
        
        # Invert distance (Closer = Higher Score)
        center_score = 1.0 - (dist / max_dist)
        
        # Combine: We weight Center Score higher to favor held objects
        final_score = area_score + (center_score * CENTER_BIAS_WEIGHT)
        return final_score

    def start(self):
        cap = cv2.VideoCapture(0)
        cap.set(cv2.CAP_PROP_FPS, 30)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        
        print("--- NORTHSTAR FOCUS MODE ---")
        print("Center your target to lock on.")

        while self.running:
            ret, frame = cap.read()
            if not ret: break
            
            h, w, _ = frame.shape
            display_frame = frame.copy()
            
            # Draw Aiming Crosshair (Visual Guide)
            cx, cy = w // 2, h // 2
            cv2.line(display_frame, (cx-20, cy), (cx+20, cy), (200, 200, 200), 1)
            cv2.line(display_frame, (cx, cy-20), (cx, cy+20), (200, 200, 200), 1)

            # YOLO Detect
            results = self.yolo(frame, verbose=False, stream=True)
            
            # Parse all detections first
            candidates = []
            for r in results:
                for box in r.boxes:
                    label = self.yolo.names[int(box.cls[0])]
                    conf = float(box.conf[0])
                    if conf < 0.5: continue
                    
                    if label in OCR_TRIGGERS:
                        coords = tuple(map(int, box.xyxy[0]))
                        score = self.calculate_focus_score(coords, w, h)
                        candidates.append((label, coords, score))

            # --- LOCK LOGIC ---
            best_candidate = None
            
            # A. If we are already LOCKED, try to maintain it
            if self.locked_label:
                # Look for our locked label specifically
                matches = [c for c in candidates if c[0] == self.locked_label]
                
                if matches:
                    # Found it again! Update lock
                    best_candidate = max(matches, key=lambda x: x[2]) # Best match
                    self.last_seen_time = time.time()
                else:
                    # We lost visual... check timeout
                    if time.time() - self.last_seen_time > LOCK_TIMEOUT:
                        print(" [System] Lock Lost.")
                        self.locked_label = None # Release lock
                        self.locked_box = None
            
            # B. If NOT locked, look for the best new target
            if not self.locked_label and candidates:
                # Sort by Focus Score (High = Center/Large)
                best_candidate = max(candidates, key=lambda x: x[2])
                
                # Only lock if it's "worthy" (Score > threshold)
                if best_candidate[2] > 0.8: # Threshold prevents locking onto tiny background noise
                    self.locked_label = best_candidate[0]
                    self.last_seen_time = time.time()
                    print(f" [System] Locked on: {self.locked_label}")

            # --- DRAWING ---
            
            # Draw Non-Locked Objects (Blue, Dim)
            for label, box, score in candidates:
                if label != self.locked_label:
                    x1, y1, x2, y2 = box
                    cv2.rectangle(display_frame, (x1, y1), (x2, y2), (100, 50, 0), 1)

            # Draw LOCKED Object (Green, Bright, Smoothed)
            if best_candidate and self.locked_label:
                label, raw_box, score = best_candidate
                
                # Smooth the jitter
                self.locked_box = self.smoother.smooth(label, raw_box)
                x1, y1, x2, y2 = self.locked_box
                
                # Visual Tether (Line from Center to Object)
                obj_cx, obj_cy = (x1+x2)//2, (y1+y2)//2
                cv2.line(display_frame, (cx, cy), (obj_cx, obj_cy), (0, 255, 0), 2)
                
                # Box
                cv2.rectangle(display_frame, (x1, y1), (x2, y2), (0, 255, 0), 3)
                cv2.putText(display_frame, f"LOCKED: {label}", (x1, y1-15), 
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
                
                # Request OCR periodically
                if time.time() - self.last_ocr_time > OCR_COOLDOWN:
                    # Crop logic
                    crop_x1 = max(0, x1-10)
                    crop_y1 = max(0, y1-10)
                    crop_x2 = min(w, x2+10)
                    crop_y2 = min(h, y2+10)
                    roi = frame[crop_y1:crop_y2, crop_x1:crop_x2]
                    
                    self.ocr_worker.request_ocr(roi.copy())
                    self.last_ocr_time = time.time()

            # Display Text
            with self.ocr_worker.lock:
                text = self.ocr_worker.latest_text
            
            if self.locked_label and len(text) > 2:
                cv2.rectangle(display_frame, (0, 640), (1280, 720), (0,0,0), -1)
                cv2.putText(display_frame, f"READING: {text}", (30, 690), 
                            cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)

            # Scene Description
            if time.time() % 5 < 0.1:
                 threading.Thread(target=self.scene_brain.analyze, args=(frame.copy(),)).start()
            
            with self.scene_brain.lock:
                desc = self.scene_brain.current_description
            
            cv2.rectangle(display_frame, (0, 0), (1280, 40), (0,0,0), -1)
            cv2.putText(display_frame, f"SCENE: {desc}", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 255), 1)

            cv2.imshow("NorthStar Focus", display_frame)
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break
        
        cap.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":
    app = NorthStarFocus()
    app.start()