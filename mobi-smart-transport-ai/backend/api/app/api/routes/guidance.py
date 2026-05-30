from __future__ import annotations

from fastapi import APIRouter

from app.schemas.guidance import (
    CreateSessionRequest,
    GuidanceSession,
    ResetRequest,
    StartGuidanceRequest,
    TransitionRequest,
)
from app.services import guidance_state_service as svc

router = APIRouter()


@router.post("/session", response_model=GuidanceSession)
def create_session(req: CreateSessionRequest) -> GuidanceSession:
    return svc.create_or_get_session(
        session_id=req.sessionId,
        user_id=req.userId,
        wake_word=req.wakeWord,
    )


@router.get("/state", response_model=GuidanceSession)
def get_state(sessionId: str = "demo-session-001") -> GuidanceSession:
    return svc.get_session_or_404(sessionId)


@router.post("/state/reset", response_model=GuidanceSession)
def reset_state(req: ResetRequest) -> GuidanceSession:
    return svc.reset_session(req.sessionId)


@router.post("/start", response_model=GuidanceSession)
def start_guidance(req: StartGuidanceRequest) -> GuidanceSession:
    return svc.start_guidance(
        session_id=req.sessionId,
        selected_stop_id=req.selectedStopId,
        selected_stop_name=req.selectedStopName,
        selected_route_no=req.selectedRouteNo,
        target_bus_id=req.targetBusId,
        target_arrival_minutes=req.targetArrivalMinutes,
        selected_route_id=req.selectedRouteId,
    )


@router.post("/transition", response_model=GuidanceSession)
def make_transition(req: TransitionRequest) -> GuidanceSession:
    return svc.transition(req.sessionId, req.targetState)
