from __future__ import annotations

from fastapi import HTTPException

from app.schemas.guidance import (
    ALLOWED_TRANSITIONS,
    BoardingConfirmResponse,
    BusEventResponse,
    GuidanceSession,
    GuidanceState,
)
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


def confirm_boarding(session_id: str, boarded: bool) -> BoardingConfirmResponse:
    from app.services import route_recommendation_service as rec_svc
    session = get_session_or_404(session_id)

    if boarded:
        updated = session.model_copy(update={"guidanceState": GuidanceState.BOARDED})
        store.save_session(updated)
        return BoardingConfirmResponse(
            guidanceState=GuidanceState.BOARDED.value,
            message="탑승을 확인했습니다. 목적지 근처에서 다시 안내해드리겠습니다.",
            shouldSpeak=True,
        )

    stop_id = session.selectedStopId or "mock-stop-001"
    route_no = session.selectedRouteNo or "502"

    try:
        arrivals = rec_svc.get_arrivals(stop_id, route_no)
        next_arrival = arrivals.arrivals[1] if len(arrivals.arrivals) > 1 else None
        fallback = arrivals.fallbackSource
    except Exception:
        next_arrival = None
        fallback = "MOCK"

    updated = session.model_copy(update={"guidanceState": GuidanceState.WAITING_FOR_BUS})
    store.save_session(updated)

    if next_arrival:
        msg = (
            f"알겠습니다. 다음 {route_no}번 버스는 약 {next_arrival.arrivalMinutes}분 뒤 도착 예정입니다. "
            "다음 버스로 다시 안내하겠습니다."
        )
        return BoardingConfirmResponse(
            guidanceState=GuidanceState.WAITING_FOR_BUS.value,
            previousState=GuidanceState.MISSED_BUS.value,
            nextRouteNo=route_no,
            nextArrivalMinutes=next_arrival.arrivalMinutes,
            message=msg,
            shouldSpeak=True,
            fallbackSource=fallback,
        )

    return BoardingConfirmResponse(
        guidanceState=GuidanceState.WAITING_FOR_BUS.value,
        previousState=GuidanceState.MISSED_BUS.value,
        nextRouteNo=route_no,
        message=f"다음 {route_no}번 버스 정보를 가져오는 중입니다. 잠시 기다려 주세요.",
        shouldSpeak=True,
        fallbackSource=fallback or "MOCK",
    )


def handle_bus_event(session_id: str, event: str) -> BusEventResponse:
    session = get_session_or_404(session_id)
    route_no = session.selectedRouteNo or "502"

    if event == "BUS_PASSED":
        passable_states = {
            GuidanceState.WAITING_FOR_BUS,
            GuidanceState.BUS_APPROACHING,
            GuidanceState.BOARDING_CONFIRMATION,
        }
        if session.guidanceState in passable_states:
            updated = session.model_copy(update={"guidanceState": GuidanceState.BOARDING_CONFIRMATION})
            store.save_session(updated)
        return BusEventResponse(
            guidanceState=GuidanceState.BOARDING_CONFIRMATION.value,
            message=f"{route_no}번 버스가 정류장을 통과했습니다. 탑승하셨나요?",
            shouldSpeak=True,
        )

    if event == "BUS_ARRIVED":
        updated = session.model_copy(update={"guidanceState": GuidanceState.BOARDING_CONFIRMATION})
        store.save_session(updated)
        return BusEventResponse(
            guidanceState=GuidanceState.BOARDING_CONFIRMATION.value,
            message=f"{route_no}번 버스가 도착했습니다. 탑승하셨나요?",
            shouldSpeak=True,
        )

    raise HTTPException(status_code=400, detail=f"알 수 없는 event: {event}")
