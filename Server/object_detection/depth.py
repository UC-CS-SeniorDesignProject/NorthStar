import logging
import os

import numpy as np
import torch
from PIL import Image
from transformers import pipeline

logger = logging.getLogger("object_detection.depth")


class DepthEstimator:
    def __init__(self) -> None:
        model_name = os.getenv("DEPTH_MODEL", "depth-anything/Depth-Anything-V2-Small-hf")
        device_str = "cuda" if torch.cuda.is_available() else "cpu"

        logger.info("Loading depth model=%s device=%s", model_name, device_str)
        os.environ["HF_HUB_OFFLINE"] = "1"
        try:
            self.pipe = pipeline(
                "depth-estimation",
                model=model_name,
                device=0 if device_str == "cuda" else -1,
            )
        finally:
            os.environ.pop("HF_HUB_OFFLINE", None)
        self._device = device_str

        if os.getenv("DEPTH_WARMUP", "1") == "1":
            blank = Image.new("RGB", (64, 64))
            try:
                self.pipe(blank)
                logger.info("Depth estimator warmup complete")
            except Exception as e:
                logger.warning("Depth warmup failed (continuing): %s", e)

    @property
    def device(self) -> str:
        return self._device

    def estimate(self, image: Image.Image) -> np.ndarray:
        result = self.pipe(image)
        depth = result["depth"]
        if isinstance(depth, Image.Image):
            depth = np.array(depth)
        return depth
