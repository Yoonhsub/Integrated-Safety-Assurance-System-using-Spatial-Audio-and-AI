from __future__ import annotations

from fastapi import APIRouter

from app.schemas.agent import ConverseRequest, ConverseResponse
from app.services import agent_orchestrator

router = APIRouter()


@router.post("/converse", response_model=ConverseResponse)
def converse(req: ConverseRequest) -> ConverseResponse:
    result = agent_orchestrator.process(
        session_id=req.sessionId,
        utterance=req.utterance,
        lat=req.lat,
        lng=req.lng,
    )
    return ConverseResponse(**result)
