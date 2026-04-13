import asyncio
import logging
from typing import Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel

from server.auth import require_api_key

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/rag", tags=["rag"], dependencies=[Depends(require_api_key)])


class RAGRequest(BaseModel):
    scene: str
    profile: Optional[str] = None


class RAGResponse(BaseModel):
    guidance: str
    best_match: str
    distance: float


@router.post("", response_model=RAGResponse)
async def rag_generate(body: RAGRequest, request: Request):
    rag = request.app.state.rag_module

    if body.profile:
        try:
            rag.load_user_profile(body.profile)
        except FileNotFoundError:
            pass

    loop = asyncio.get_event_loop()
    answer, retrieved = await loop.run_in_executor(
        None, rag.generate_response, body.scene
    )

    return RAGResponse(
        guidance=answer,
        best_match=retrieved.text,
        distance=retrieved.distance,
    )