import asyncio
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from .cache import TTLCache
from .metrics import REQUEST_LATENCY, REQUESTS_TOTAL

from pathlib import Path

from ocr.engine import OcrEngine
from ocr.routes import router as ocr_router
from object_detection.detector import YoloDetector
from object_detection.routes import router as detection_router

import sys

RAG_BASE = Path(__file__).resolve().parent.parent / "NorthStar-RAG" / "NorthStar"
sys.path.insert(0, str(RAG_BASE))

from rag.rag_module import RAGModule
from rag.routes import router as rag_router

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "WARNING"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
for _quiet in ("httpx", "httpcore", "huggingface_hub", "urllib3", "modelscope",
               "paddle", "paddlex", "transformers", "sentence_transformers"):
    logging.getLogger(_quiet).setLevel(logging.ERROR)


@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        app.state.engine = OcrEngine()
    except Exception as e:
        logging.getLogger("server").warning("OCR engine failed to load, OCR disabled: %s", e)
        app.state.engine = None
    app.state.cache = TTLCache(
        max_items=int(os.getenv("OCR_CACHE_MAX_ITEMS", "128")),
        ttl_seconds=int(os.getenv("OCR_CACHE_TTL_SECONDS", "300")),
    )
    app.state.semaphore = asyncio.Semaphore(int(os.getenv("OCR_MAX_CONCURRENT", "1")))

    app.state.detector = YoloDetector()
    app.state.detect_semaphore = asyncio.Semaphore(
        int(os.getenv("YOLO_MAX_CONCURRENT", "1"))
    )

    if os.getenv("DEPTH_ENABLED", "1") == "1":
        try:
            from object_detection.depth import DepthEstimator
            app.state.depth_estimator = DepthEstimator()
        except Exception as e:
            logging.getLogger("server").warning("Depth estimation failed to load, continuing without it: %s", e)
            app.state.depth_estimator = None
    else:
        app.state.depth_estimator = None

    if os.getenv("SCENE_ENABLED", "1") == "1":
        try:
            from object_detection.scene import SceneDescriber
            app.state.scene_describer = SceneDescriber()
        except Exception as e:
            logging.getLogger("server").warning("Scene describer failed to load, continuing without it: %s", e)
            app.state.scene_describer = None
    else:
        app.state.scene_describer = None

    rag = RAGModule(
        knowledge_path=RAG_BASE / "knowledge_base.txt",
        profile_dir=RAG_BASE / "user_profiles",
    )
    try:
        rag.load_user_profile("default")
    except FileNotFoundError:
        pass
    app.state.rag_module = rag

    app.state.startup_info = {
        "ocr": app.state.engine is not None,
        "detector": True,
        "depth": app.state.depth_estimator is not None,
    }

    yield


app = FastAPI(title="Vision Server", version="1.1.0", lifespan=lifespan)
app.include_router(ocr_router)
app.include_router(detection_router)
app.include_router(rag_router)

@app.get("/healthz")
async def healthz():
    return {"status": "ok"}

@app.get("/readyz")
async def readyz(request: Request):
    engine = getattr(request.app.state, "engine", None)
    detector = getattr(request.app.state, "detector", None)
    if engine is None:
        raise HTTPException(status_code=503, detail="OCR engine not loaded")
    if detector is None:
        raise HTTPException(status_code=503, detail="Detection engine not loaded")
    return {
        "status": "ready",
        "paddleocr_version": engine.paddleocr_version,
        "yolo_device": detector.device,
    }

@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.middleware("http")
async def request_id_and_metrics(request: Request, call_next):
    path = request.url.path
    method = request.method
    start = time.perf_counter()
    req_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())
    request.state.request_id = req_id

    try:
        response = await call_next(request)
    except Exception:
        REQUESTS_TOTAL.labels(path=path, method=method, status="500").inc()
        raise
    finally:
        REQUEST_LATENCY.labels(path=path, method=method).observe(time.perf_counter() - start)

    response.headers["X-Request-ID"] = req_id
    REQUESTS_TOTAL.labels(path=path, method=method, status=str(response.status_code)).inc()
    return response
