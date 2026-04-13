from dotenv import load_dotenv
load_dotenv()

import os
import socket
import uvicorn

from server import app


def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "unknown"


if __name__ == "__main__":
    local_ip = get_local_ip()
    port = 8000
    yolo_model = os.getenv("YOLO_MODEL", "yolo12x.pt")
    ocr_device = os.getenv("OCR_DEVICE", "gpu")
    depth_enabled = os.getenv("DEPTH_ENABLED", "1") == "1"

    print()
    print("=" * 55)
    print("  NorthStar Vision Server")
    print("=" * 55)
    print(f"  YOLO Model:       {yolo_model}")
    print(f"  OCR Engine:       EasyOCR ({ocr_device})")
    print(f"  Depth Estimation: {'Enabled' if depth_enabled else 'Disabled'}")
    print(f"  RAG Knowledge:    Loaded")
    print("-" * 55)
    print(f"  Local:            http://localhost:{port}")
    print(f"  Network:          http://{local_ip}:{port}")
    print(f"  API Key Header:   X-API-Key: {os.getenv('OCR_API_KEY', 'test')}")
    print("-" * 55)
    print(f"  Point your app to: http://{local_ip}:{port}")
    print("=" * 55)
    print()

    uvicorn.run(app, host="0.0.0.0", port=port)