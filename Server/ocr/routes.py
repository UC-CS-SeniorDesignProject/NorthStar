import asyncio
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple

from fastapi import APIRouter, Depends, HTTPException, Request

from server.auth import require_api_key
from server.cache import TTLCache
from server.image import b64_to_bytes, decode_to_bgr, sha256_bytes

from . import debug_visual
from .engine import OcrEngine
from .layout import group_into_regions
from .models import (
    CacheInfo,
    ModelInfo,
    OcrBatchRequest,
    OcrBlock,
    OcrJsonRequest,
    OcrOptions,
    OcrPage,
    OcrResponse,
    TimingMs,
)

router = APIRouter()


def _normalize_result(item: Any) -> Dict[str, Any]:
    if isinstance(item, dict) and "res" in item:
        return item["res"]
    if hasattr(item, "res"):
        return getattr(item, "res")
    if isinstance(item, dict):
        return item
    raise ValueError(f"Unexpected PaddleOCR result type: {type(item)}")


def _build_response(
    *,
    request_id: str,
    content_sha: str,
    width: int,
    height: int,
    paddle_items: List[Any],
    timing_ms: Dict[str, float],
    cache_hit: bool,
    cache_key: Optional[str],
    paddleocr_version: str,
    img_bgr: Optional[Any] = None,
    enable_debug: bool = False,
) -> OcrResponse:
    pages: List[OcrPage] = []

    for page_i, item in enumerate(paddle_items):
        res = _normalize_result(item)

        rec_texts = res.get("rec_texts") if res.get("rec_texts") is not None else []
        rec_scores = res.get("rec_scores") if res.get("rec_scores") is not None else []
        rec_polys = res.get("rec_polys") if res.get("rec_polys") is not None else []
        rec_boxes = res.get("rec_boxes") if res.get("rec_boxes") is not None else []

        count = min(len(rec_texts), len(rec_scores), len(rec_polys), len(rec_boxes))
        blocks: List[OcrBlock] = []

        for i in range(count):
            poly = rec_polys[i]
            box = rec_boxes[i]
            poly_list = poly.tolist() if hasattr(poly, "tolist") else poly
            box_list = box.tolist() if hasattr(box, "tolist") else box

            blocks.append(OcrBlock(
                id=f"p{page_i}_b{i}",
                text=str(rec_texts[i]),
                confidence=float(rec_scores[i]),
                polygon=[[float(x), float(y)] for x, y in poly_list],
                bbox_xyxy=[float(v) for v in box_list],
            ))

        if enable_debug and img_bgr is not None:
            debug_visual.save_detections(img_bgr, blocks, request_id)

        blocks, full_text = group_into_regions(blocks)

        if enable_debug and img_bgr is not None:
            debug_visual.save_regions(img_bgr, blocks, request_id)

        pages.append(OcrPage(page_index=page_i, blocks=blocks, full_text=full_text))

    return OcrResponse(
        request_id=request_id,
        content_sha256=content_sha,
        width=width,
        height=height,
        pages=pages,
        timing_ms=TimingMs(**timing_ms),
        cache=CacheInfo(hit=cache_hit, key=cache_key),
        model=ModelInfo(paddleocr_version=paddleocr_version),
    )


@router.post("/v1/ocr", response_model=OcrResponse)
async def ocr_single(request: Request, _api_key: str = Depends(require_api_key)):
    req_id = getattr(request.state, "request_id", str(uuid.uuid4()))
    content_type = (request.headers.get("content-type") or "").lower()

    t0 = time.perf_counter()
    options = OcrOptions()

    t_decode = time.perf_counter()
    if content_type.startswith("application/json"):
        body = await request.json()
        parsed = OcrJsonRequest.model_validate(body)
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
                options = OcrOptions.model_validate_json(str(form["options"]))
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"Invalid options JSON: {e}")
    else:
        raise HTTPException(status_code=415, detail="Use application/json or multipart/form-data")
    decode_ms = (time.perf_counter() - t_decode) * 1000.0

    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image payload")

    if options.debug:
        debug_visual.save_input(image_bytes, req_id)

    content_sha = sha256_bytes(image_bytes)

    t_pre = time.perf_counter()
    img_bgr, w, h = decode_to_bgr(image_bytes, max_side=options.max_side, exif_transpose=options.exif_transpose)
    preprocess_ms = (time.perf_counter() - t_pre) * 1000.0

    if options.debug:
        debug_visual.save_preprocessed(img_bgr, req_id)

    engine: OcrEngine = request.app.state.engine
    cache: TTLCache = request.app.state.cache
    cache_key = f"{content_sha}:{options.cache_key_fragment()}:{engine.paddleocr_version}"

    cached = cache.get(cache_key)
    if cached is not None:
        cached.cache.hit = True
        cached.cache.key = cache_key
        cached.request_id = req_id
        cached.timing_ms.total = (time.perf_counter() - t0) * 1000.0
        return cached

    sem: asyncio.Semaphore = request.app.state.semaphore
    async with sem:
        t_infer = time.perf_counter()
        paddle_items = await asyncio.to_thread(engine.predict, img_bgr, options)
        infer_ms = (time.perf_counter() - t_infer) * 1000.0

    t_post = time.perf_counter()
    resp = _build_response(
        request_id=req_id,
        content_sha=content_sha,
        width=w,
        height=h,
        paddle_items=paddle_items,
        timing_ms={"decode": decode_ms, "preprocess": preprocess_ms, "ocr_infer": infer_ms, "postprocess": 0.0, "total": 0.0},
        cache_hit=False,
        cache_key=cache_key,
        paddleocr_version=engine.paddleocr_version,
        img_bgr=img_bgr if options.debug else None,
        enable_debug=options.debug,
    )
    resp.timing_ms.postprocess = (time.perf_counter() - t_post) * 1000.0
    resp.timing_ms.total = (time.perf_counter() - t0) * 1000.0

    cache.set(cache_key, resp)
    return resp


@router.post("/v1/ocr/batch")
async def ocr_batch(payload: OcrBatchRequest, request: Request, _api_key: str = Depends(require_api_key)):
    req_id = payload.request_id or str(uuid.uuid4())
    options = payload.options or OcrOptions()

    imgs: List = []
    dims: List[Tuple[int, int]] = []
    shas: List[str] = []

    for b64 in payload.images_b64:
        raw = b64_to_bytes(b64)
        shas.append(sha256_bytes(raw))
        img_bgr, w, h = decode_to_bgr(raw, max_side=options.max_side, exif_transpose=options.exif_transpose)
        imgs.append(img_bgr)
        dims.append((w, h))

    engine: OcrEngine = request.app.state.engine
    sem: asyncio.Semaphore = request.app.state.semaphore

    async with sem:
        items = await asyncio.to_thread(engine.predict_batch, imgs, options, payload.use_predict_iter)

    zero_timing = {"decode": 0.0, "preprocess": 0.0, "ocr_infer": 0.0, "postprocess": 0.0, "total": 0.0}
    results = [
        _build_response(
            request_id=f"{req_id}:{i}",
            content_sha=shas[i],
            width=dims[i][0],
            height=dims[i][1],
            paddle_items=[item],
            timing_ms=zero_timing,
            cache_hit=False,
            cache_key=None,
            paddleocr_version=engine.paddleocr_version,
        ).model_dump(mode="json")
        for i, item in enumerate(items)
    ]

    return {"request_id": req_id, "results": results}
