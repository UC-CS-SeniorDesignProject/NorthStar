from prometheus_client import Counter, Histogram

REQUESTS_TOTAL = Counter(
    "ocr_server_requests_total", "Total HTTP requests", ["path", "method", "status"]
)
REQUEST_LATENCY = Histogram(
    "ocr_server_request_latency_seconds", "Request latency", ["path", "method"]
)
OCR_INFER_LATENCY = Histogram(
    "ocr_server_ocr_infer_seconds", "OCR inference latency (end-to-end OCR call)"
)
