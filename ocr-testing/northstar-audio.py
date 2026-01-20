import cv2
import easyocr
import threading
import time
import torch
import queue
import math
import numpy as np
import sounddevice as sd
from difflib import SequenceMatcher
from ultralytics import YOLO
from transformers import BlipProcessor, BlipForConditionalGeneration, VitsModel, AutoTokenizer
from PIL import Image

# --- CONFIGURATION ---
OCR_TRIGGERS = [
    'book', 'traffic light', 'stop sign', 'parking meter', 
    'remote', 'cell phone', 'laptop', 'monitor', 'tv', 
    'clock', 'sign', 'screen', 'menu', 'bottle', 'cup'
]

OCR_COOLDOWN = 0.8
LOCK_TIMEOUT = 3.0
CENTER_BIAS_WEIGHT = 2.5

class NeuralVoice(threading.Thread):
    """ The 'Mouth' of the AI - Uses Facebook MMS (VITS) for realistic offline speech """
    def __init__(self):
        super().__init__()
        self.queue = queue.Queue()
        self.daemon = True
        self.is_speaking = False
        
        print(" [Init] Loading Neural Voice (MMS)...")
        self.tokenizer = AutoTokenizer.from_pretrained("facebook/mms-tts-eng")
        self.model = VitsModel.from_pretrained("facebook/mms-tts-eng")
        self.model.to("cpu")
        self.start()

    def run(self):
        while True:
            text = self.queue.get()
            self.is_speaking = True
            try:
                # Generate Audio
                inputs = self.tokenizer(text, return_tensors="pt")
                with torch.no_grad():
                    output = self.model(**inputs).waveform
                
                audio_np = output.float().numpy().flatten()
                
                # Play Audio (Blocking until finished, so we don't talk over ourselves)
                sd.play(audio_np, samplerate=self.model.config.sampling_rate)
                sd.wait()
            except Exception as e:
                print(f"TTS Error: {e}")
            finally:
                self.is_speaking = False
                self.queue.task_done()

    def say(self, text):
        # Don't queue if the queue is already backed up
        if self.queue.qsize() < 2:
            self.queue.put(text)

class TextStabilizer:
    """ Prevents the AI from reading 'Hello W..' -> 'Hello Worl..' -> 'Hello World' """
    def __init__(self):
        self.history = []
        self.last_spoken = ""
        self.last_spoken_time = 0
        self.confidence_threshold = 3 # Needs to see same text 3 times to speak

    def update_and_check(self, new_text):
        if len(new_text) < 2: return None
        
        # Add to history buffer (Keep last 5)
        self.history.append(new_text)
        if len(self.history) > 5: self.history.pop(0)
        
        # Check if the last 3 entries are similar
        if len(self.history) >= self.confidence_threshold:
            recent = self.history[-self.confidence_threshold:]
            # If all recent texts are basically the same
            if all(self.is_similar(new_text, t) for t in recent):
                
                # Check cooldown (Don't repeat same sentence for 10s)
                if (new_text != self.last_spoken) or (time.time() - self.last_spoken_time > 10):
                    self.last_spoken = new_text
                    self.last_spoken_time = time.time()
                    return new_text
        return None

    def is_similar(self, a, b):
        return SequenceMatcher(None, a, b).ratio() > 0.85

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

    def enhance_card_image(self, img):
        img = cv2.resize(img, (0, 0), fx=2.0, fy=2.0, interpolation=cv2.INTER_CUBIC)
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8,8))
        contrast = clahe.apply(gray)
        kernel = np.array([[0, -1, 0], [-1, 5,-1], [0, -1, 0]])
        return cv2.filter2D(contrast, -1, kernel)

    def request_ocr(self, roi):
        if not self.input_queue.full():
            self.input_queue.put(roi)

    def run(self):
        while True:
            roi = self.input_queue.get()
            try:
                processed_roi = self.enhance_card_image(roi)
                results = self.reader.readtext(processed_roi, detail=0, paragraph=True)
                text = " ".join(results)
                with self.lock:
                    self.latest_text = text
            except: pass
            finally:
                self.input_queue.task_done()

class NorthStarAudio:
    def __init__(self):
        print(" [Init] Loading YOLOv8...")
        self.yolo = YOLO('yolov8s.pt') 
        
        self.scene_brain = SceneBrain()
        self.ocr_worker = OCRWorker()
        self.ocr_worker.start()
        self.voice = NeuralVoice()
        
        # Stabilizers
        self.text_stabilizer = TextStabilizer()
        
        self.running = True
        self.locked_label = None 
        self.last_seen_time = 0
        self.last_ocr_time = 0
        self.last_scene_speak_time = 0

    def calculate_focus_score(self, box, frame_w, frame_h):
        x1, y1, x2, y2 = box
        area_score = ((x2-x1) * (y2-y1)) / (frame_w * frame_h)
        
        box_cx, box_cy = (x1 + x2) / 2, (y1 + y2) / 2
        dist = math.sqrt((box_cx - frame_w/2)**2 + (box_cy - frame_h/2)**2)
        center_score = 1.0 - (dist / math.sqrt((frame_w/2)**2 + (frame_h/2)**2))
        
        return area_score + (center_score * CENTER_BIAS_WEIGHT)

    def start(self):
        cap = cv2.VideoCapture(0) # <--- CHECK YOUR CAMERA INDEX
        cap.set(cv2.CAP_PROP_FPS, 30)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        
        print("--- NORTHSTAR AUDIO ACTIVE ---")
        self.voice.say("North Star Online.")

        while self.running:
            ret, frame = cap.read()
            if not ret: break
            
            h, w, _ = frame.shape
            display_frame = frame.copy()
            
            # Draw Crosshair
            cx, cy = w // 2, h // 2
            cv2.line(display_frame, (cx-20, cy), (cx+20, cy), (200, 200, 200), 1)
            cv2.line(display_frame, (cx, cy-20), (cx, cy+20), (200, 200, 200), 1)

            # YOLO
            results = self.yolo(frame, verbose=False, stream=True)
            candidates = []
            
            for r in results:
                for box in r.boxes:
                    label = self.yolo.names[int(box.cls[0])]
                    if box.conf[0] < 0.45: continue
                    if label in OCR_TRIGGERS:
                        coords = tuple(map(int, box.xyxy[0]))
                        candidates.append((label, coords, self.calculate_focus_score(coords, w, h)))

            # Lock Logic
            best_candidate = None
            if self.locked_label:
                matches = [c for c in candidates if c[0] == self.locked_label]
                if matches:
                    best_candidate = max(matches, key=lambda x: x[2]) 
                    self.last_seen_time = time.time()
                elif time.time() - self.last_seen_time > LOCK_TIMEOUT:
                    self.locked_label = None 
            
            if not self.locked_label and candidates:
                best_new = max(candidates, key=lambda x: x[2])
                if best_new[2] > 0.7:
                    self.locked_label = best_new[0]
                    self.last_seen_time = time.time()

            # Drawing & Logic
            if best_candidate and self.locked_label:
                label, (x1, y1, x2, y2), score = best_candidate
                
                # Draw Locked Box
                cv2.rectangle(display_frame, (x1, y1), (x2, y2), (0, 255, 0), 3)
                cv2.putText(display_frame, f"LOCKED: {label}", (x1, y1-15), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
                
                # Request OCR
                if time.time() - self.last_ocr_time > OCR_COOLDOWN:
                    crop = frame[max(0, y1-15):min(h, y2+15), max(0, x1-15):min(w, x2+15)]
                    self.ocr_worker.request_ocr(crop.copy())
                    self.last_ocr_time = time.time()

            # --- AUDIO FEEDBACK LOGIC ---
            
            # 1. OCR Voice Trigger
            with self.ocr_worker.lock:
                raw_text = self.ocr_worker.latest_text
            
            # Process Stability
            stable_text = self.text_stabilizer.update_and_check(raw_text)
            
            # If we have a stable new text AND we are currently locked onto an object
            if stable_text and self.locked_label:
                print(f"Speaking: {stable_text}")
                self.voice.say(stable_text)

            # 2. Scene Voice Trigger (Every 15s)
            if time.time() - self.last_scene_speak_time > 15.0:
                # Trigger update
                threading.Thread(target=self.scene_brain.analyze, args=(frame.copy(),)).start()
                
                with self.scene_brain.lock:
                    desc = self.scene_brain.current_description
                
                # Only speak if it's a valid description
                if len(desc) > 10 and "Analyzing" not in desc:
                    self.voice.say(f"Scene: {desc}")
                    self.last_scene_speak_time = time.time()

            # Display
            if self.locked_label and len(raw_text) > 2:
                cv2.rectangle(display_frame, (0, 640), (1280, 720), (0,0,0), -1)
                cv2.putText(display_frame, f"READ: {raw_text}", (30, 690), cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
                
            cv2.imshow("NorthStar Audio", display_frame)
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break
        
        cap.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":
    app = NorthStarAudio()
    app.start()