import importlib.util
import threading
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

VISION_PATH = Path(__file__).with_name("northstar-vision.py")
MODULE_NAME = "northstar_vision_module"

spec = importlib.util.spec_from_file_location(MODULE_NAME, VISION_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Unable to load module from {VISION_PATH}")

northstar_vision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(northstar_vision)
NorthStarFocus = northstar_vision.NorthStarFocus


class StartRequest(BaseModel):
    camera_index: int = Field(default=0, ge=0)
    display: bool = False


class VisionRuntimeController:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._runtime: Optional[NorthStarFocus] = None
        self._thread: Optional[threading.Thread] = None

    def _status_unlocked(self) -> Dict[str, Any]:
        thread_alive = self._thread is not None and self._thread.is_alive()
        if self._runtime is None:
            return {
                "running": False,
                "thread_alive": False,
                "detail": "NorthStar runtime has not been started yet.",
            }

        state = self._runtime.get_state()
        state["thread_alive"] = thread_alive
        return state

    def status(self) -> Dict[str, Any]:
        with self._lock:
            return self._status_unlocked()

    def start(self, camera_index: int, display: bool) -> Dict[str, Any]:
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                raise RuntimeError("NorthStar runtime is already running.")

            self._runtime = NorthStarFocus(camera_index=camera_index, display=display)
            self._thread = threading.Thread(
                target=self._runtime.start,
                daemon=True,
                name="NorthStarFocusThread",
            )
            self._thread.start()
            return self._status_unlocked()

    def stop(self, timeout_seconds: float = 5.0) -> Dict[str, Any]:
        with self._lock:
            runtime = self._runtime
            thread = self._thread

        if runtime is None:
            return {
                "running": False,
                "thread_alive": False,
                "detail": "NorthStar runtime is not running.",
            }

        runtime.stop()
        if thread is not None and thread.is_alive():
            thread.join(timeout=timeout_seconds)

        return self.status()


controller = VisionRuntimeController()
api = FastAPI(title="NorthStar Controller", version="1.0.0")

# Allow local Flutter web dev servers (localhost/127.0.0.1 on any port).
api.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@api.get("/health")
def health() -> Dict[str, str]:
    return {"status": "ok"}


@api.get("/controller/status")
def controller_status() -> Dict[str, Any]:
    return controller.status()


@api.post("/controller/start")
def controller_start(payload: StartRequest) -> Dict[str, Any]:
    try:
        return controller.start(camera_index=payload.camera_index, display=payload.display)
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@api.post("/controller/stop")
def controller_stop() -> Dict[str, Any]:
    return controller.stop()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(api, host="0.0.0.0", port=8001)
