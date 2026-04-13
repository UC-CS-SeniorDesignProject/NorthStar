import logging
import os
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
from PIL import Image

logger = logging.getLogger("object_detection")


def _iou(a: List[float], b: List[float]) -> float:
    xi1 = max(a[0], b[0])
    yi1 = max(a[1], b[1])
    xi2 = min(a[2], b[2])
    yi2 = min(a[3], b[3])
    inter = max(0.0, xi2 - xi1) * max(0.0, yi2 - yi1)
    area_a = (a[2] - a[0]) * (a[3] - a[1])
    area_b = (b[2] - b[0]) * (b[3] - b[1])
    union = area_a + area_b - inter
    if union <= 0:
        return 0.0
    return inter / union


class YoloDetector:
    def __init__(self) -> None:
        from ultralytics import YOLO

        model_path = os.getenv("YOLO_MODEL", "yolov8x.pt")
        device = os.getenv("YOLO_DEVICE", "auto")

        logger.info("Loading YOLOv8 model=%s device=%s", model_path, device)
        self.model = YOLO(model_path)

        if device == "auto":
            try:
                self.model.to("cuda")
                self._device = "cuda"
                logger.info("YOLOv8 running on CUDA GPU")
            except Exception:
                self._device = "cpu"
                logger.info("CUDA unavailable, YOLOv8 running on CPU")
        elif device == "cpu":
            self._device = "cpu"
        else:
            self.model.to(device)
            self._device = device
            logger.info("YOLOv8 running on %s", device)

        self._conf_threshold = float(os.getenv("YOLO_CONF_THRESHOLD", "0.40"))
        self._iou_match_threshold = float(os.getenv("YOLO_IOU_MATCH_THRESHOLD", "0.30"))

        self._last_detections: List[Dict[str, Any]] = []

        if os.getenv("YOLO_WARMUP", "1") == "1":
            blank = np.zeros((64, 64, 3), dtype=np.uint8)
            try:
                self.model.predict(source=blank, verbose=False)
                logger.info("YOLOv8 warmup complete")
            except Exception as e:
                logger.warning("YOLOv8 warmup failed (continuing): %s", e)

    @property
    def device(self) -> str:
        return self._device

    @property
    def model_name(self) -> str:
        return str(self.model.model_name) if hasattr(self.model, "model_name") else "yolov8"

    def _parse_results(self, results) -> List[Dict[str, Any]]:
        detections: List[Dict[str, Any]] = []
        res = results[0]
        boxes = res.boxes
        names = res.names

        for i in range(len(boxes)):
            conf = float(boxes.conf[i])
            if conf < self._conf_threshold:
                continue
            cls_id = int(boxes.cls[i])
            label = names[cls_id]
            xyxy = boxes.xyxy[i].tolist()
            detections.append({
                "label": label,
                "confidence": round(conf, 3),
                "bbox": [round(v, 1) for v in xyxy],
            })

        return detections

    def _diff_detections(
        self,
        current: List[Dict[str, Any]],
        previous: List[Dict[str, Any]],
    ) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        def group_by_label(dets):
            groups: Dict[str, List[Dict[str, Any]]] = {}
            for d in dets:
                groups.setdefault(d["label"], []).append(d)
            return groups

        curr_groups = group_by_label(current)
        prev_groups = group_by_label(previous)
        all_labels = set(curr_groups) | set(prev_groups)

        appeared: List[Dict[str, Any]] = []
        disappeared: List[Dict[str, Any]] = []

        for label in all_labels:
            curr_objs = list(curr_groups.get(label, []))
            prev_objs = list(prev_groups.get(label, []))

            matched_curr = set()
            matched_prev = set()

            pairs: List[Tuple[float, int, int]] = []
            for ci, c in enumerate(curr_objs):
                for pi, p in enumerate(prev_objs):
                    score = _iou(c["bbox"], p["bbox"])
                    if score >= self._iou_match_threshold:
                        pairs.append((score, ci, pi))

            pairs.sort(key=lambda x: x[0], reverse=True)

            for _, ci, pi in pairs:
                if ci in matched_curr or pi in matched_prev:
                    continue
                matched_curr.add(ci)
                matched_prev.add(pi)

            for ci, c in enumerate(curr_objs):
                if ci not in matched_curr:
                    appeared.append(c)

            for pi, p in enumerate(prev_objs):
                if pi not in matched_prev:
                    disappeared.append(p)

        return appeared, disappeared

    def detect(self, image: Image.Image) -> Dict[str, Any]:
        results = self.model.predict(source=image, verbose=False)
        detections = self._parse_results(results)

        appeared, disappeared = self._diff_detections(detections, self._last_detections)
        self._last_detections = detections

        changed = len(appeared) > 0 or len(disappeared) > 0

        return {
            "changed": changed,
            "objects": detections if changed else [],
            "appeared": [{"label": d["label"], "confidence": d["confidence"], "bbox": d["bbox"]} for d in appeared],
            "disappeared": [{"label": d["label"], "confidence": d["confidence"], "bbox": d["bbox"]} for d in disappeared],
        }

    def detect_raw(self, image: Image.Image) -> List[Dict[str, Any]]:
        results = self.model.predict(source=image, verbose=False)
        return self._parse_results(results)

    def reset_scene(self) -> None:
        self._last_detections = []
