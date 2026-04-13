import logging
import os
from pathlib import Path
from typing import List

import numpy as np
from PIL import Image, ImageDraw, ImageFont

logger = logging.getLogger("ocr.debug")

REGION_COLORS = [
    (230, 25, 75),    # red
    (60, 180, 75),    # green
    (0, 130, 200),    # blue
    (245, 130, 48),   # orange
    (145, 30, 180),   # purple
    (240, 50, 230),   # magenta
    (210, 245, 60),   # lime
    (0, 128, 128),    # teal
    (170, 110, 40),   # brown
    (128, 0, 0),      # maroon
]


def _get_debug_dir() -> Path:
    d = Path(os.getenv("OCR_DEBUG_DIR", "debug_output"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def _try_load_font(size: int = 14):
    try:
        return ImageFont.truetype("arial.ttf", size)
    except OSError:
        try:
            return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)
        except OSError:
            return ImageFont.load_default()


def save_input(image_bytes: bytes, request_id: str) -> None:
    out = _get_debug_dir() / f"{request_id}_1_input.png"
    try:
        img = Image.open(__import__("io").BytesIO(image_bytes))
        img.save(out)
        logger.info("Debug step 1 saved: %s", out)
    except Exception as e:
        logger.warning("Debug step 1 failed: %s", e)


def save_preprocessed(img_bgr: np.ndarray, request_id: str) -> None:
    out = _get_debug_dir() / f"{request_id}_2_preprocessed.png"
    try:
        rgb = img_bgr[:, :, ::-1]
        Image.fromarray(rgb).save(out)
        logger.info("Debug step 2 saved: %s", out)
    except Exception as e:
        logger.warning("Debug step 2 failed: %s", e)


def save_detections(img_bgr: np.ndarray, blocks: list, request_id: str) -> None:
    out = _get_debug_dir() / f"{request_id}_3_detections.png"
    try:
        rgb = img_bgr[:, :, ::-1]
        img = Image.fromarray(rgb).convert("RGB")
        draw = ImageDraw.Draw(img)
        font = _try_load_font(14)

        for block in blocks:
            x1, y1, x2, y2 = block.bbox_xyxy
            draw.rectangle([x1, y1, x2, y2], outline=(0, 200, 0), width=2)
            label = f"{block.text} ({block.confidence:.0%})"
            draw.text((x1, max(0, y1 - 16)), label, fill=(0, 200, 0), font=font)

        img.save(out)
        logger.info("Debug step 3 saved: %s", out)
    except Exception as e:
        logger.warning("Debug step 3 failed: %s", e)


def save_regions(img_bgr: np.ndarray, blocks: list, request_id: str) -> None:
    out = _get_debug_dir() / f"{request_id}_4_regions.png"
    try:
        rgb = img_bgr[:, :, ::-1]
        img = Image.fromarray(rgb).convert("RGB")
        draw = ImageDraw.Draw(img)
        font = _try_load_font(14)

        for block in blocks:
            color = REGION_COLORS[block.region % len(REGION_COLORS)]
            x1, y1, x2, y2 = block.bbox_xyxy
            draw.rectangle([x1, y1, x2, y2], outline=color, width=2)
            label = f"R{block.region}: {block.text}"
            draw.text((x1, max(0, y1 - 16)), label, fill=color, font=font)

        img.save(out)
        logger.info("Debug step 4 saved: %s", out)
    except Exception as e:
        logger.warning("Debug step 4 failed: %s", e)
