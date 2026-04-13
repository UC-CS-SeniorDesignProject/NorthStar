import os
from typing import Optional

from fastapi import Depends, HTTPException
from fastapi.security import APIKeyHeader

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def require_api_key(x_api_key: Optional[str] = Depends(_api_key_header)) -> str:
    expected = os.getenv("OCR_API_KEY")
    if not expected:
        raise HTTPException(status_code=500, detail="Server misconfigured: OCR_API_KEY is not set")
    if not x_api_key or x_api_key != expected:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return x_api_key
