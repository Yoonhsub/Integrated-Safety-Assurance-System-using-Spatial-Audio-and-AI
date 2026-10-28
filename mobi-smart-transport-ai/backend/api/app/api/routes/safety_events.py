from fastapi import APIRouter, Query

from app.schemas.safety_event import SafetyEventCreate, SafetyEventRecord, SafetyEventsRecentResponse
from app.services.safety_event_service import SafetyEventService

router = APIRouter()
_service = SafetyEventService()


@router.post("", response_model=SafetyEventRecord)
def create_safety_event(payload: SafetyEventCreate, sessionId: str | None = None,
                        generation: str | None = None) -> SafetyEventRecord:
    from app.services import session_safety_delivery as delivery
    if sessionId is not None or generation is not None:
        delivery.validate_binding(sessionId, generation, payload)
    record = _service.create(payload)
    if sessionId is not None:
        delivery.publish(sessionId, generation, record)
    return record


@router.get("/recent", response_model=SafetyEventsRecentResponse)
def list_recent_safety_events(limit: int = Query(default=20, ge=1, le=100)) -> SafetyEventsRecentResponse:
    return _service.recent(limit=limit)
