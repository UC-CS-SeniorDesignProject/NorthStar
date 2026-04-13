import asyncio
import io
import logging
import time
import uuid
from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, Request
from PIL import Image

from server.auth import require_api_key
from server.image import b64_to_bytes

from .detector import YoloDetector
from .models import (
    DetectJsonRequest,
    DetectOptions,
    DetectResponse,
    DetectionDiff,
    DetectionObject,
)

router = APIRouter()
logger = logging.getLogger("object_detection")

_last_announced: dict[str, float] = {}
COOLDOWN_SECONDS = float(__import__("os").getenv("DETECT_COOLDOWN_SECONDS", "5"))

MAX_GUIDANCE_CHARS = int(__import__("os").getenv("DETECT_MAX_GUIDANCE_CHARS", "200"))

AUTO_OCR_ENABLED = False
_ocr_cooldown: dict[str, float] = {}
OCR_COOLDOWN_SECONDS = float(__import__("os").getenv("OCR_COOLDOWN_SECONDS", "10"))

_ALWAYS_OCR = {
    "stop sign", "sign", "book", "tv", "laptop", "cell phone",
    "clock", "parking meter", "traffic light",
}

_NEVER_OCR = {
    "person", "dog", "cat", "bird", "horse", "cow", "sheep", "bear",
    "apple", "banana", "orange", "broccoli", "carrot", "sandwich",
    "hot dog", "pizza", "donut", "cake", "sports ball", "frisbee",
    "kite", "teddy bear", "toothbrush", "spoon", "fork", "knife",
    "hair drier", "mouse", "remote", "tie", "skateboard",
    "skis", "snowboard", "surfboard", "baseball bat", "tennis racket",
    "potted plant", "vase", "scissors", "fire hydrant",
}

FOCUS_THRESHOLD = float(__import__("os").getenv("OCR_FOCUS_THRESHOLD", "0.15"))


def _should_ocr(label: str, bbox: list[float], img_w: int, img_h: int) -> bool:
    label_lower = label.lower()

    if label_lower in _ALWAYS_OCR:
        return True

    if label_lower in _NEVER_OCR:
        return False

    frac = _bbox_area_fraction(bbox, img_w, img_h)
    return frac >= FOCUS_THRESHOLD


def _crop_bbox(image: Image.Image, bbox: list[float], padding: int = 10) -> Image.Image:
    x1 = max(0, int(bbox[0]) - padding)
    y1 = max(0, int(bbox[1]) - padding)
    x2 = min(image.width, int(bbox[2]) + padding)
    y2 = min(image.height, int(bbox[3]) + padding)
    return image.crop((x1, y1, x2, y2))


async def _auto_ocr(image: Image.Image, objects: list, engine, ocr_options,
                     img_w: int, img_h: int) -> str:
    import numpy as np

    if engine is None:
        return ""

    now = time.time()
    candidates = []

    for obj in objects:
        label = obj.label
        bbox = obj.bbox

        if not _should_ocr(label, bbox, img_w, img_h):
            continue

        cx, cy = int((bbox[0] + bbox[2]) / 2), int((bbox[1] + bbox[3]) / 2)
        cooldown_key = f"{label}_{cx // 50}_{cy // 50}"
        last = _ocr_cooldown.get(cooldown_key, 0)
        if now - last < OCR_COOLDOWN_SECONDS:
            continue

        frac = _bbox_area_fraction(bbox, img_w, img_h)
        priority = 1.0 + frac if label.lower() in _ALWAYS_OCR else frac
        candidates.append((priority, cooldown_key, label, bbox))

    if not candidates:
        return ""

    candidates.sort(key=lambda x: x[0], reverse=True)

    texts = []
    for priority, cooldown_key, label, bbox in candidates[:2]:
        try:
            crop = _crop_bbox(image, bbox)
            if crop.width < 20 or crop.height < 10:
                continue
            crop_bgr = np.array(crop)[:, :, ::-1]
            results = await asyncio.to_thread(engine.predict, crop_bgr, ocr_options)
            for res in results:
                rec_texts = res.get("rec_texts", []) if isinstance(res, dict) else []
                for t in rec_texts:
                    t = t.strip()
                    if t and len(t) >= 2:
                        texts.append(t)
            if texts:
                _ocr_cooldown[cooldown_key] = now
        except Exception as e:
            logger.debug("Auto-OCR failed for %s: %s", label, e)

    if len(_ocr_cooldown) > 50:
        stale = [k for k, v in _ocr_cooldown.items() if now - v > 60]
        for k in stale:
            del _ocr_cooldown[k]

    if texts:
        combined = " ".join(texts)
        return f' It reads: "{combined}".'
    return ""


def _image_from_bytes(raw: bytes) -> Image.Image:
    try:
        return Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception as e:
        raise HTTPException(status_code=415, detail=f"Unsupported/invalid image: {e}")


def _detect_motion_blur(image: Image.Image, bbox: list[float]) -> str:
    import numpy as np

    try:
        x1, y1, x2, y2 = int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])
        crop = image.crop((max(0, x1), max(0, y1), min(image.width, x2), min(image.height, y2)))
        if crop.width < 10 or crop.height < 10:
            return "stationary"

        gray = np.array(crop.convert("L"), dtype=np.float64)
        mean_brightness = gray.mean()

        if mean_brightness < 50:
            return "stationary"

        laplacian = np.array([
            [0, 1, 0],
            [1, -4, 1],
            [0, 1, 0]
        ], dtype=np.float64)

        from scipy.signal import convolve2d
        filtered = convolve2d(gray, laplacian, mode="valid")
        variance = filtered.var()

        if variance < 30:
            return "moving fast"
        elif variance < 100:
            return "moving"
        return "stationary"
    except Exception:
        return "stationary"


_prev_positions: dict[str, tuple[float, float, float]] = {}


def _estimate_velocity(label: str, bbox: list[float], img_w: int) -> str:
    now = time.time()
    cx = (bbox[0] + bbox[2]) / 2
    cy = (bbox[1] + bbox[3]) / 2

    key = label
    prev = _prev_positions.get(key)
    _prev_positions[key] = (cx, cy, now)

    if prev is None:
        return ""

    pcx, pcy, pt = prev
    dt = now - pt
    if dt <= 0 or dt > 2.0:
        return ""

    dx = (cx - pcx) / img_w
    dy = (cy - pcy) / img_w

    speed = (dx**2 + dy**2) ** 0.5 / dt

    if speed > 0.15:
        if dy > 0.05:
            return "approaching quickly"
        elif dy < -0.05:
            return "moving away quickly"
        elif dx > 0.05:
            return "moving right quickly"
        elif dx < -0.05:
            return "moving left quickly"
        return "moving quickly"
    elif speed > 0.03:
        if dy > 0.02:
            return "approaching"
        elif dy < -0.02:
            return "moving away"
        return "moving"
    return ""

_env_state: dict[str, float] = {}
ENV_COOLDOWN = 120.0

def _analyze_ambient_light(image: Image.Image) -> str:
    import numpy as np
    try:
        w, h = image.size
        crop = image.crop((w // 4, h // 4, 3 * w // 4, 3 * h // 4))
        gray = np.array(crop.convert("L"))
        mean_brightness = gray.mean()

        if mean_brightness < 30:
            condition = "very dark"
        elif mean_brightness < 55:
            condition = "dim"
        elif mean_brightness > 235:
            condition = "very bright"
        else:
            return ""

        now = time.time()
        last = _env_state.get(condition, 0)
        if now - last < ENV_COOLDOWN:
            return ""
        _env_state[condition] = now
        return condition
    except Exception:
        pass
    return ""


def _analyze_crowd(objects_list: list) -> str:
    person_count = sum(1 for o in objects_list if o.label.lower() == "person")
    if person_count >= 6:
        condition = "crowded area with many people"
    elif person_count >= 3:
        condition = "multiple people nearby"
    else:
        return ""

    now = time.time()
    last = _env_state.get("crowd", 0)
    if now - last < ENV_COOLDOWN:
        return ""
    _env_state["crowd"] = now
    return condition


def _confidence_language(label: str, confidence: float) -> str:
    _urgent_labels = {"car", "truck", "bus", "motorcycle", "train", "fire", "bear"}
    if confidence >= 0.6 or label.lower() not in _urgent_labels:
        return label
    elif confidence >= 0.4:
        return f"maybe {label}"
    return ""


def _bbox_area_fraction(bbox: list[float], img_w: int, img_h: int) -> float:
    w = max(0, bbox[2] - bbox[0])
    h = max(0, bbox[3] - bbox[1])
    img_area = img_w * img_h
    if img_area == 0:
        return 0.0
    return (w * h) / img_area


def _estimate_distance_ft(bbox: list[float], img_w: int, img_h: int, depth_map=None) -> float:
    if depth_map is not None:
        cx = int((bbox[0] + bbox[2]) / 2)
        cy = int((bbox[1] + bbox[3]) / 2)
        h, w = depth_map.shape[:2]
        scale_x = w / img_w
        scale_y = h / img_h
        dx = min(max(int(cx * scale_x), 0), w - 1)
        dy = min(max(int(cy * scale_y), 0), h - 1)
        depth_val = float(depth_map[dy, dx])
        if depth_val > 0:
            return max(2.0, 50.0 - (depth_val / 255.0) * 48.0)

    frac = _bbox_area_fraction(bbox, img_w, img_h)
    if frac >= 0.25:
        return 3.0
    elif frac >= 0.15:
        return 5.0
    elif frac >= 0.08:
        return 10.0
    elif frac >= 0.03:
        return 20.0
    return 35.0


def _estimate_proximity(bbox: list[float], img_w: int, img_h: int, depth_map=None) -> str:
    dist = _estimate_distance_ft(bbox, img_w, img_h, depth_map)
    if dist <= 5:
        return "close"
    elif dist <= 15:
        return "near"
    return "far"


def _estimate_direction(bbox: list[float], img_w: int) -> str:
    cx = (bbox[0] + bbox[2]) / 2
    ratio = cx / img_w
    if ratio < 0.3:
        return "to your left"
    elif ratio > 0.7:
        return "to your right"
    elif ratio < 0.4:
        return "to your front-left"
    elif ratio > 0.6:
        return "to your front-right"
    return "directly ahead"


def _infer_pose(label: str, bbox: list[float], img_h: int) -> str:
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    if w <= 0 or h <= 0:
        return ""
    aspect = w / h
    bottom_ratio = bbox[3] / img_h

    label_lower = label.lower()

    if label_lower in ("person",):
        if aspect > 1.5:
            return "lying down"
        elif aspect > 0.9 and bottom_ratio > 0.7:
            return "sitting"
        return ""

    if label_lower in ("dog", "cat"):
        if aspect > 2.0:
            return "resting"
        elif aspect > 1.3:
            return "lying down"
        return ""

    if label_lower in ("car", "truck", "bus", "motorcycle"):
        if bottom_ratio > 0.85:
            return "parked nearby"
        return ""

    if label_lower in ("bicycle",):
        if bottom_ratio > 0.85:
            return "parked"
        return ""

    return ""


def _describe_object_spatial(label: str, bbox: list[float], img_w: int, img_h: int,
                              depth_map=None, image: Image.Image = None,
                              confidence: float = 1.0) -> str:
    raw_label = label.lower()
    display_label = _confidence_language(label, confidence)
    dist = _estimate_distance_ft(bbox, img_w, img_h, depth_map)
    direction = _estimate_direction(bbox, img_w)

    if dist <= 3:
        dist_str = "very close"
    elif dist <= 6:
        dist_str = f"about {int(round(dist))} feet"
    elif dist <= 15:
        dist_str = f"about {int(round(dist / 5) * 5)} feet"
    else:
        dist_str = f"about {int(round(dist / 10) * 10)} feet"

    velocity = _estimate_velocity(raw_label, bbox, img_w)

    _moving_labels = {"person", "car", "truck", "bus", "motorcycle", "bicycle", "dog", "cat"}
    if not velocity and image and raw_label in _moving_labels:
        blur = _detect_motion_blur(image, bbox)
        if blur != "stationary":
            velocity = blur

    pose = "" if velocity else _infer_pose(raw_label, bbox, img_h)

    if velocity:
        return f"{display_label} {velocity} {dist_str} {direction}"
    elif pose:
        return f"{display_label} {pose} {dist_str} {direction}"
    return f"{display_label} {dist_str} {direction}"


def _apply_cooldown(labels: list[str]) -> list[str]:
    now = time.time()
    fresh = []
    for label in labels:
        last = _last_announced.get(label, 0)
        if now - last >= COOLDOWN_SECONDS:
            fresh.append(label)
            _last_announced[label] = now

    if len(_last_announced) > 100:
        stale = [k for k, v in _last_announced.items() if now - v > 60]
        for k in stale:
            del _last_announced[k]

    return fresh


def _sort_by_urgency(labels: list[str], rag) -> list[str]:
    urgent = []
    normal = []
    for label in labels:
        response = rag.get_response_for_token(label.lower())
        if response.startswith("URGENT"):
            urgent.append(label)
        else:
            normal.append(label)
    return urgent + normal


def _extract_action(tip: str) -> str:
    tip = tip.replace("URGENT: ", "")
    if ";" in tip:
        return tip.split(";", 1)[1].strip()
    return tip.strip()


def _cap_guidance(text: str) -> str:
    if len(text) <= MAX_GUIDANCE_CHARS:
        return text
    truncated = text[:MAX_GUIDANCE_CHARS]
    last_period = truncated.rfind(".")
    if last_period > 0:
        return truncated[:last_period + 1]
    return truncated + "..."


def _build_spatial_labels(diffs: list, img_w: int, img_h: int, depth_map=None, image=None) -> list[str]:
    spatial = []
    for d in diffs:
        bbox = d.bbox if hasattr(d, "bbox") else d["bbox"]
        label = d.label if hasattr(d, "label") else d["label"]
        conf = d.confidence if hasattr(d, "confidence") else 1.0
        desc = _describe_object_spatial(label, bbox, img_w, img_h, depth_map, image, conf)
        spatial.append(desc)
    return spatial


@router.post("/v1/detect", response_model=DetectResponse)
async def detect_endpoint(request: Request, _api_key: str = Depends(require_api_key)):
    req_id = getattr(request.state, "request_id", str(uuid.uuid4()))
    content_type = (request.headers.get("content-type") or "").lower()

    t0 = time.perf_counter()
    options = DetectOptions()

    if content_type.startswith("application/json"):
        body = await request.json()
        parsed = DetectJsonRequest.model_validate(body)
        if parsed.options:
            options = parsed.options
        if parsed.request_id:
            req_id = parsed.request_id
        image_bytes = b64_to_bytes(parsed.image_b64)
    elif content_type.startswith("multipart/form-data"):
        form = await request.form()
        file = form.get("file")
        if file is None:
            raise HTTPException(status_code=400, detail="Missing form field: file")
        image_bytes = await file.read()
        if "options" in form:
            try:
                options = DetectOptions.model_validate_json(str(form["options"]))
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"Invalid options JSON: {e}")
    else:
        raise HTTPException(status_code=415, detail="Use application/json or multipart/form-data")

    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image payload")

    image = _image_from_bytes(image_bytes)
    img_w, img_h = image.size
    detector: YoloDetector = request.app.state.detector
    depth_estimator = getattr(request.app.state, "depth_estimator", None)
    sem: asyncio.Semaphore = request.app.state.detect_semaphore

    async with sem:
        if options.reset_scene:
            detector.reset_scene()

        if options.skip_dedup:
            raw = await asyncio.to_thread(detector.detect_raw, image)
            result = {
                "changed": True,
                "objects": raw,
                "appeared": [],
                "disappeared": [],
            }
        else:
            result = await asyncio.to_thread(detector.detect, image)

    has_changes = len(result["appeared"]) > 0 or len(result["disappeared"]) > 0
    has_objects = len(result["objects"]) > 0
    is_complex = len(result["objects"]) >= 3

    depth_map = None
    scene_caption = ""
    scene_describer = getattr(request.app.state, "scene_describer", None)

    async def _run_depth():
        if depth_estimator and has_objects:
            try:
                return await asyncio.to_thread(depth_estimator.estimate, image)
            except Exception as e:
                logger.debug("Depth failed: %s", e)
        return None

    async def _run_scene():
        if scene_describer and has_changes and is_complex:
            try:
                return await asyncio.to_thread(scene_describer.describe, image)
            except Exception as e:
                logger.debug("Scene description failed: %s", e)
        return ""

    if has_objects:
        depth_map, scene_caption = await asyncio.gather(_run_depth(), _run_scene())

    objects_list = [
        DetectionObject(
            **o, proximity=_estimate_proximity(o["bbox"], img_w, img_h, depth_map)
        ) for o in result["objects"]
    ]
    appeared_list = [
        DetectionDiff(
            **a, proximity=_estimate_proximity(a["bbox"], img_w, img_h, depth_map)
        ) for a in result["appeared"]
    ]
    disappeared_list = [
        DetectionDiff(
            **d, proximity=_estimate_proximity(d["bbox"], img_w, img_h, depth_map)
        ) for d in result["disappeared"]
    ]

    rag = request.app.state.rag_module
    changed_diffs = appeared_list + disappeared_list
    guidance = ""
    _retrieved = []

    try:
        if changed_diffs:
            changed_labels = [d.label for d in changed_diffs]
            fresh_labels = _apply_cooldown(changed_labels)

            if fresh_labels:
                fresh_diffs = [d for d in changed_diffs if d.label in fresh_labels]
                sorted_labels = _sort_by_urgency(fresh_labels, rag)
                spatial = _build_spatial_labels(
                    [d for d in fresh_diffs if d.label in sorted_labels],
                    img_w, img_h, depth_map, image
                )
                parts = []
                for i, desc in enumerate(spatial):
                    diff = [d for d in fresh_diffs if d.label in sorted_labels][i] if i < len(fresh_diffs) else None
                    base_label = diff.label.lower() if diff else desc.split()[0].lower()
                    tip = rag.get_response_for_token(base_label)
                    if tip.startswith("URGENT"):
                        action = _extract_action(tip)
                        parts.append(f"{desc.capitalize()}. {action}")
                    else:
                        parts.append(f"{desc.capitalize()}.")
                guidance = " ".join(parts[:3])
        elif objects_list:
            relevant_objs = []
            for o in objects_list:
                dist = _estimate_distance_ft(o.bbox, img_w, img_h, depth_map)
                is_urgent = rag.get_response_for_token(o.label.lower()).startswith("URGENT")
                velocity = _estimate_velocity(o.label.lower(), o.bbox, img_w)
                is_approaching = "approaching" in velocity if velocity else False
                if dist > 25 and not is_urgent and not is_approaching:
                    continue
                relevant_objs.append(o)

            all_labels = [o.label for o in relevant_objs]
            fresh_labels = _apply_cooldown(all_labels)

            if fresh_labels:
                fresh_objs = [o for o in relevant_objs if o.label in fresh_labels]
                fresh_objs_sorted = sorted(
                    fresh_objs,
                    key=lambda o: (
                        0 if rag.get_response_for_token(o.label.lower()).startswith("URGENT") else 1,
                        _estimate_distance_ft(o.bbox, img_w, img_h, depth_map)
                    )
                )

                if len(fresh_objs_sorted) >= 5:
                    labels = [o.label for o in fresh_objs_sorted]
                    unique = list(dict.fromkeys(labels))
                    summary = ", ".join(unique[:5])
                    urgent = [o for o in fresh_objs_sorted
                              if rag.get_response_for_token(o.label.lower()).startswith("URGENT")]
                    if urgent:
                        closest = urgent[0]
                        desc = _describe_object_spatial(
                            closest.label, closest.bbox, img_w, img_h, depth_map, image, closest.confidence
                        )
                        tip = _extract_action(rag.get_response_for_token(closest.label.lower()))
                        guidance = f"Busy area with {summary}. {desc.capitalize()}; {tip}"
                    else:
                        guidance = f"Nearby: {summary}."
                else:
                    spatial = _build_spatial_labels(fresh_objs_sorted[:3], img_w, img_h, depth_map, image)
                    parts = []
                    for i, desc in enumerate(spatial):
                        base_label = fresh_objs_sorted[i].label.lower() if i < len(fresh_objs_sorted) else desc.split()[0].lower()
                        tip = rag.get_response_for_token(base_label)
                        if tip.startswith("URGENT"):
                            action = _extract_action(tip)
                            parts.append(f"{desc.capitalize()}. {action}")
                        else:
                            parts.append(f"{desc.capitalize()}.")
                    guidance = " ".join(parts[:3])
    except Exception as e:
        logger.error("RAG guidance failed: %s", e)
        guidance = ""

    try:
        if guidance:
            light = _analyze_ambient_light(image)
            if light == "very dark":
                guidance = "Very dark. " + guidance
            elif light == "dim":
                guidance = "Low light. " + guidance

            crowd = _analyze_crowd(objects_list)
            if crowd:
                guidance = f"{crowd}. " + guidance
    except Exception:
        pass

    if AUTO_OCR_ENABLED:
        try:
            from ocr.models import OcrOptions
            ocr_engine = getattr(request.app.state, "engine", None)
            ocr_text = await _auto_ocr(image, objects_list, ocr_engine, OcrOptions(), img_w, img_h)
            if ocr_text:
                guidance = (guidance + ocr_text) if guidance else ocr_text.strip()
        except Exception as e:
            logger.debug("Auto-OCR step failed: %s", e)

    if guidance:
        guidance = _cap_guidance(guidance)

    elapsed = (time.perf_counter() - t0) * 1000.0

    if guidance:
        print(f"[DETECT] {elapsed:.0f}ms | {[o.label for o in objects_list]} → {guidance}")

    from server.detection_log import log_detection
    log_detection(
        request_id=req_id,
        objects=objects_list,
        appeared=appeared_list,
        disappeared=disappeared_list,
        guidance=guidance,
        timing_ms=elapsed,
        depth_available=depth_map is not None,
    )

    return DetectResponse(
        request_id=req_id,
        changed=result["changed"],
        objects=objects_list,
        appeared=appeared_list,
        disappeared=disappeared_list,
        guidance=guidance,
        device=detector.device,
        timing_ms=round(elapsed, 2),
    )


@router.post("/v1/detect/reset")
async def reset_scene(request: Request, _api_key: str = Depends(require_api_key)):
    detector: YoloDetector = request.app.state.detector
    detector.reset_scene()
    _last_announced.clear()
    return {"status": "scene_reset"}
