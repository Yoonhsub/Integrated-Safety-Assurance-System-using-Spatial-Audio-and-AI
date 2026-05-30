from __future__ import annotations

from fastapi import APIRouter

from app.schemas.guidance import BusEventRequest, BusEventResponse
from app.services.guidance_state_service import handle_bus_event

router = APIRouter()


@router.post("/bus-event", response_model=BusEventResponse)
def mock_bus_event(req: BusEventRequest) -> BusEventResponse:
    return handle_bus_event(req.sessionId, req.event)
