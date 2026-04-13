import csv
import os
import time
from datetime import datetime
from pathlib import Path
from threading import Lock

LOG_DIR = Path(os.getenv("DETECT_LOG_DIR", "logs"))
MAX_FILE_SIZE = 50 * 1024 * 1024
MAX_FILES = 7

_lock = Lock()
_writer = None
_file = None
_current_date = None
_current_path = None

FIELDS = [
    "timestamp", "request_id", "objects", "appeared", "disappeared",
    "guidance", "timing_ms", "depth_available", "object_count",
]


def _rotate_if_needed():
    global _writer, _file, _current_date, _current_path

    today = datetime.now().strftime("%Y-%m-%d")
    need_rotate = (
        _file is None
        or _current_date != today
        or (_current_path and _current_path.exists() and _current_path.stat().st_size > MAX_FILE_SIZE)
    )

    if not need_rotate:
        return

    if _file:
        try:
            _file.close()
        except Exception:
            pass

    LOG_DIR.mkdir(parents=True, exist_ok=True)

    existing = sorted(LOG_DIR.glob("detections_*.csv"))
    while len(existing) >= MAX_FILES:
        try:
            existing[0].unlink()
        except Exception:
            pass
        existing.pop(0)

    _current_date = today
    _current_path = LOG_DIR / f"detections_{today}.csv"
    write_header = not _current_path.exists()

    _file = open(_current_path, "a", newline="", encoding="utf-8")
    _writer = csv.DictWriter(_file, fieldnames=FIELDS)
    if write_header:
        _writer.writeheader()


def log_detection(
    request_id: str,
    objects: list,
    appeared: list,
    disappeared: list,
    guidance: str,
    timing_ms: float,
    depth_available: bool,
):
    try:
        with _lock:
            _rotate_if_needed()
            _writer.writerow({
                "timestamp": datetime.now().isoformat(),
                "request_id": request_id,
                "objects": "|".join(o.label for o in objects),
                "appeared": "|".join(a.label for a in appeared),
                "disappeared": "|".join(d.label for d in disappeared),
                "guidance": guidance,
                "timing_ms": f"{timing_ms:.0f}",
                "depth_available": "Y" if depth_available else "N",
                "object_count": len(objects),
            })
            _file.flush()
    except Exception:
        pass
