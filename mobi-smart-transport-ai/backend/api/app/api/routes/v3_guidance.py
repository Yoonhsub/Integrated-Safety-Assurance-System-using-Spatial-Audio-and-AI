from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.schemas.v3 import GuidanceEventRequest, GuidanceSessionCreateRequest, GuidanceSessionState, GuidanceState
from app.services.v3_guidance_store import V3SessionRecord, v3_guidance_store

router = APIRouter()


def _bad_transition(event: str, state: GuidanceState) -> HTTPException:
    return HTTPException(
        status_code=409,
        detail={
            "error": {
                "code": "INVALID_GUIDANCE_TRANSITION",
                "message": "The requested V3 guidance state transition is not allowed.",
                "detail": {"event": event, "currentState": state.value},
            }
        },
    )


def _apply_route_payload(session: V3SessionRecord, payload: dict) -> None:
    session.selected_destination = payload.get("destination") or session.selected_destination
    session.selected_route_no = payload.get("routeNo") or session.selected_route_no
    session.selected_route_id = payload.get("routeId") or session.selected_route_id
    session.selected_stop_id = payload.get("stopId") or session.selected_stop_id
    session.selected_stop_name = payload.get("stopName") or session.selected_stop_name
    session.target_bus_id = payload.get("targetBusId") or session.target_bus_id


@router.post("/session", response_model=GuidanceSessionState)
def create_session(payload: GuidanceSessionCreateRequest) -> GuidanceSessionState:
    return v3_guidance_store.create(session_id=payload.sessionId, wake_word=payload.wakeWord).to_response()


@router.get("/state", response_model=GuidanceSessionState)
def get_state(sessionId: str = "demo-session") -> GuidanceSessionState:
    return v3_guidance_store.get(sessionId).to_response()


@router.post("/reset", response_model=GuidanceSessionState)
def reset_session(payload: GuidanceEventRequest) -> GuidanceSessionState:
    return v3_guidance_store.reset(payload.sessionId).to_response()


@router.post("/event", response_model=GuidanceSessionState)
def apply_event(payload: GuidanceEventRequest) -> GuidanceSessionState:
    session = v3_guidance_store.get(payload.sessionId)
    event = payload.event.strip().upper()

    if event == "ROUTE_RECOMMENDED":
        _apply_route_payload(session, payload.payload)
        session.state = GuidanceState.ROUTE_RECOMMENDED
    elif event == "ROUTE_SELECTED":
        _apply_route_payload(session, payload.payload)
        session.state = GuidanceState.ROUTE_SELECTED
    elif event == "NAVIGATING_TO_STOP":
        if session.state not in {GuidanceState.ROUTE_SELECTED, GuidanceState.ROUTE_RECOMMENDED, GuidanceState.WAITING_FOR_BUS}:
            raise _bad_transition(event, session.state)
        session.state = GuidanceState.NAVIGATING_TO_STOP
    elif event == "ARRIVED_AT_STOP":
        if session.state == GuidanceState.IDLE:
            raise _bad_transition(event, session.state)
        session.state = GuidanceState.ARRIVED_AT_STOP
        session.geofence_armed = True
    elif event == "WAITING_FOR_BUS":
        if session.state == GuidanceState.IDLE:
            raise _bad_transition(event, session.state)
        session.state = GuidanceState.WAITING_FOR_BUS
    elif event == "BOARDING_CONFIRMATION":
        if session.state not in {GuidanceState.ARRIVED_AT_STOP, GuidanceState.WAITING_FOR_BUS, GuidanceState.REPLAN_NEXT_BUS}:
            raise _bad_transition(event, session.state)
        session.state = GuidanceState.BOARDING_CONFIRMATION
    elif event == "BOARDED":
        if session.state != GuidanceState.BOARDING_CONFIRMATION:
            raise _bad_transition(event, session.state)
        session.state = GuidanceState.BOARDED
    elif event == "MISSED_BUS":
        if session.state not in {GuidanceState.BOARDING_CONFIRMATION, GuidanceState.WAITING_FOR_BUS, GuidanceState.REPLAN_NEXT_BUS}:
            raise _bad_transition(event, session.state)
        session.state = GuidanceState.MISSED_BUS
    elif event == "REPLAN_NEXT_BUS":
        if session.state != GuidanceState.MISSED_BUS:
            raise _bad_transition(event, session.state)
        session.state = GuidanceState.REPLAN_NEXT_BUS
        if session.selected_route_no == "502":
            session.target_bus_id = "BUS_502_NEXT"
    else:
        raise HTTPException(
            status_code=400,
            detail={
                "error": {
                    "code": "UNKNOWN_GUIDANCE_EVENT",
                    "message": "Unknown V3 guidance event.",
                    "detail": {"event": event},
                }
            },
        )

    session.touch()
    return session.to_response()
