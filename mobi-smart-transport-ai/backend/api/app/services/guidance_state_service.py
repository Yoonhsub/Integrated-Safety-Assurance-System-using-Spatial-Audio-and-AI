from __future__ import annotations

from fastapi import HTTPException

from app.schemas.guidance import ALLOWED_TRANSITIONS, GuidanceSession, GuidanceState
from app.services import guidance_session_store as store


def create_or_get_session(
    session_id: str | None = None,
    user_id: str | None = None,
    wake_word: str | None = None,
) -> GuidanceSession:
    sid = session_id or "demo-session-001"
    existing = store.get_session(sid)
    if existing:
        return existing
    session = GuidanceSession(
        sessionId=sid,
        userId=user_id or "passenger-demo-001",
        wakeWord=wake_word or "자비스",
    )
    store.save_session(session)
    return session


def get_session_or_404(session_id: str) -> GuidanceSession:
    session = store.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail=f"세션을 찾을 수 없습니다: {session_id}")
    return session


def reset_session(session_id: str) -> GuidanceSession:
    existing = store.get_session(session_id)
    if not existing:
        raise HTTPException(status_code=404, detail=f"세션을 찾을 수 없습니다: {session_id}")
    reset = GuidanceSession(
        sessionId=existing.sessionId,
        userId=existing.userId,
        wakeWord=existing.wakeWord,
    )
    store.save_session(reset)
    return reset


def start_guidance(
    session_id: str,
    selected_stop_id: str,
    selected_stop_name: str,
    selected_route_no: str,
    target_bus_id: str | None = None,
    target_arrival_minutes: int | None = None,
    selected_route_id: str | None = None,
) -> GuidanceSession:
    session = get_session_or_404(session_id)
    updated = session.model_copy(update={
        "selectedStopId": selected_stop_id,
        "selectedStopName": selected_stop_name,
        "selectedRouteNo": selected_route_no,
        "targetBusId": target_bus_id,
        "targetArrivalMinutes": target_arrival_minutes,
        "selectedRouteId": selected_route_id,
        "guidanceState": GuidanceState.ROUTE_SELECTED,
    })
    store.save_session(updated)
    return updated


def transition(session_id: str, target_state: GuidanceState) -> GuidanceSession:
    session = get_session_or_404(session_id)
    allowed = ALLOWED_TRANSITIONS.get(session.guidanceState, set())
    if target_state not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"'{session.guidanceState}' 상태에서 '{target_state}'로 전이할 수 없습니다.",
        )
    updates: dict = {"guidanceState": target_state}
    if target_state == GuidanceState.ARRIVED_AT_STOP:
        updates["hasArrivedAtStop"] = True
        updates["geofenceArmed"] = True
    updated = session.model_copy(update=updates)
    store.save_session(updated)
    return updated
