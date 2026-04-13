from typing import List, Optional

from pydantic import BaseModel, Field


class DetectionObject(BaseModel):
    label: str
    confidence: float
    bbox: List[float] = Field(description="Bounding box [x1, y1, x2, y2]")
    proximity: str = Field(default="unknown", description="Estimated proximity: close, near, far")


class DetectionDiff(BaseModel):
    label: str
    confidence: float
    bbox: List[float] = Field(description="Bounding box [x1, y1, x2, y2]")
    proximity: str = Field(default="unknown", description="Estimated proximity: close, near, far")


class DetectOptions(BaseModel):
    skip_dedup: bool = Field(
        default=False,
        description="If true, bypass scene deduplication and always run detection.",
    )
    reset_scene: bool = Field(
        default=False,
        description="If true, clear stored scene state before processing.",
    )


class DetectJsonRequest(BaseModel):
    image_b64: str
    options: Optional[DetectOptions] = None
    request_id: Optional[str] = None


class DetectResponse(BaseModel):
    request_id: str
    changed: bool
    objects: List[DetectionObject]
    appeared: List[DetectionDiff]
    disappeared: List[DetectionDiff]
    guidance: str
    device: str
    timing_ms: float
