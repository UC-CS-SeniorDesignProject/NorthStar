import json
from typing import List, Optional

from pydantic import BaseModel, Field


class OcrOptions(BaseModel):
    use_doc_orientation_classify: bool = False
    use_doc_unwarping: bool = False
    use_textline_orientation: bool = False

    text_det_limit_side_len: Optional[int] = Field(default=None, ge=1)
    text_det_limit_type: Optional[str] = Field(default=None, pattern="^(min|max)$")
    text_det_thresh: Optional[float] = Field(default=None, ge=0.0)
    text_det_box_thresh: Optional[float] = Field(default=None, ge=0.0)
    text_det_unclip_ratio: Optional[float] = Field(default=None, ge=0.0)
    text_rec_score_thresh: Optional[float] = Field(default=None, ge=0.0)

    max_side: Optional[int] = Field(default=None, ge=64)
    exif_transpose: bool = True
    debug: bool = Field(default=False, description="Save annotated images after each processing step to OCR_DEBUG_DIR")

    def cache_key_fragment(self) -> str:
        return json.dumps(self.model_dump(mode="json", exclude_none=True), sort_keys=True)

    def predict_kwargs(self) -> dict:
        return {
            "use_doc_orientation_classify": self.use_doc_orientation_classify,
            "use_doc_unwarping": self.use_doc_unwarping,
            "use_textline_orientation": self.use_textline_orientation,
            "text_det_limit_side_len": self.text_det_limit_side_len,
            "text_det_limit_type": self.text_det_limit_type,
            "text_det_thresh": self.text_det_thresh,
            "text_det_box_thresh": self.text_det_box_thresh,
            "text_det_unclip_ratio": self.text_det_unclip_ratio,
            "text_rec_score_thresh": self.text_rec_score_thresh,
        }


class OcrJsonRequest(BaseModel):
    image_b64: str
    options: Optional[OcrOptions] = None
    request_id: Optional[str] = None


class OcrBatchRequest(BaseModel):
    images_b64: List[str] = Field(min_length=1, max_length=8)
    options: Optional[OcrOptions] = None
    request_id: Optional[str] = None
    use_predict_iter: bool = True


class OcrBlock(BaseModel):
    id: str
    text: str
    confidence: float
    polygon: List[List[float]]
    bbox_xyxy: List[float]
    region: int = Field(default=0, description="Spatial region/column index (left-to-right)")


class OcrPage(BaseModel):
    page_index: int
    blocks: List[OcrBlock]
    full_text: str


class ModelInfo(BaseModel):
    paddleocr_version: str


class TimingMs(BaseModel):
    decode: float
    preprocess: float
    ocr_infer: float
    postprocess: float
    total: float


class CacheInfo(BaseModel):
    hit: bool
    key: Optional[str] = None


class OcrResponse(BaseModel):
    request_id: str
    content_sha256: str
    width: int
    height: int
    pages: List[OcrPage]
    timing_ms: TimingMs
    cache: CacheInfo
    model: ModelInfo
