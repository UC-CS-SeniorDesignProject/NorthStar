import logging
import os
from typing import Any, Dict, List

import numpy as np
import easyocr

from server.metrics import OCR_INFER_LATENCY
from .models import OcrOptions

logger = logging.getLogger("ocr")


class OcrEngine:
    def __init__(self) -> None:
        device = os.getenv("OCR_DEVICE", "gpu")
        use_gpu = device.lower() != "cpu"

        logger.info("Initializing EasyOCR (device=%s)", "gpu" if use_gpu else "cpu")

        self.reader = easyocr.Reader(["en"], gpu=use_gpu, verbose=False)
        self.paddleocr_version = f"easyocr-{easyocr.__version__}"

        if os.getenv("OCR_WARMUP", "1") == "1":
            blank = np.zeros((64, 64, 3), dtype=np.uint8)
            try:
                self.reader.readtext(blank)
                logger.info("Warmup complete")
            except Exception as e:
                logger.warning("Warmup failed (continuing): %s", e)

    def predict(self, img_bgr: np.ndarray, options: OcrOptions) -> List[Dict[str, Any]]:
        with OCR_INFER_LATENCY.time():
            results = self.reader.readtext(img_bgr)
            rec_texts = []
            rec_scores = []
            rec_polys = []
            rec_boxes = []

            for (bbox, text, conf) in results:
                rec_texts.append(text)
                rec_scores.append(float(conf))
                poly = [[float(p[0]), float(p[1])] for p in bbox]
                rec_polys.append(poly)
                xs = [p[0] for p in poly]
                ys = [p[1] for p in poly]
                rec_boxes.append([min(xs), min(ys), max(xs), max(ys)])

            return [{
                "rec_texts": rec_texts,
                "rec_scores": rec_scores,
                "rec_polys": rec_polys,
                "rec_boxes": rec_boxes,
            }]

    def predict_batch(
        self, imgs_bgr: List[np.ndarray], options: OcrOptions, use_iter: bool
    ) -> List[Dict[str, Any]]:
        all_results = []
        for img in imgs_bgr:
            all_results.extend(self.predict(img, options))
        return all_results