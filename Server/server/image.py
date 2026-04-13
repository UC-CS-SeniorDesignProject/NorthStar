import base64
import hashlib
import io
from typing import Optional, Tuple

import numpy as np
from fastapi import HTTPException
from PIL import Image, ImageOps


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def b64_to_bytes(b64: str) -> bytes:
    if "," in b64 and b64.strip().lower().startswith("data:"):
        _, b64 = b64.split(",", 1)
    try:
        return base64.b64decode(b64, validate=True)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid base64: {e}")


def decode_to_bgr(
    image_bytes: bytes,
    *,
    max_side: Optional[int],
    exif_transpose: bool,
) -> Tuple[np.ndarray, int, int]:
    try:
        img = Image.open(io.BytesIO(image_bytes))
        if exif_transpose:
            img = ImageOps.exif_transpose(img)
        img = img.convert("RGB")
    except Exception as e:
        raise HTTPException(status_code=415, detail=f"Unsupported/invalid image: {e}")

    w, h = img.size
    if max_side and max(w, h) > max_side:
        img.thumbnail((max_side, max_side))
        w, h = img.size

    rgb = np.array(img, dtype=np.uint8)
    bgr = rgb[:, :, ::-1].copy()
    return bgr, w, h
