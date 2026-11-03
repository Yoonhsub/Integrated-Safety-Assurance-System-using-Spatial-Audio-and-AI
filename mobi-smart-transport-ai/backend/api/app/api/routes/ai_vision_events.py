"""Cross-process ingestion endpoint for AI Vision interpretations."""
from fastapi import APIRouter, HTTPException, Response

from app.schemas.ai_vision_safety_event import (
    AiVisionInterpretationIngestRequest,
    AiVisionInterpretationIngestResponse,
    AiVisionInterpretationStatus,
)
from app.services.ai_vision_safety_event_adapter import (
    AiVisionSafetyEventAdapter,
    SafetyInterpretationAdapterError,
)
from app.services.safety_event_service import SafetyEventService


router = APIRouter()
_adapter = AiVisionSafetyEventAdapter()
_service = SafetyEventService()


@router.post(
    "/events",
    response_model=AiVisionInterpretationIngestResponse,
    summary="Ingest an AI Vision interpretation",
)
def ingest_ai_vision_interpretation(
    payload: AiVisionInterpretationIngestRequest,
    response: Response,
    sessionId: str | None = None,
    generation: str | None = None,
) -> AiVisionInterpretationIngestResponse:
    interpretation = _adapter.from_transport_request(payload)
    try:
        safety_event = _adapter.to_safety_event_create(interpretation)
    except SafetyInterpretationAdapterError as exc:
        raise HTTPException(
            status_code=422,
            detail={
                "error": {
                    "code": "INVALID_AI_VISION_EVENT",
                    "message": str(exc),
                }
            },
        ) from exc

    if safety_event is None:
        # The report was handled, but no Safety Event was created or persisted.
        response.status_code = 200
        return AiVisionInterpretationIngestResponse(
            status=payload.status,
            stored=False,
            safetyEvent=None,
        )

    from app.services import session_safety_delivery as delivery
    if sessionId is not None or generation is not None:
        delivery.validate_binding(sessionId, generation, safety_event)
    record = _service.create(safety_event)
    if sessionId is not None:
        delivery.publish(sessionId, generation, record)
    response.status_code = 201
    return AiVisionInterpretationIngestResponse(
        status=AiVisionInterpretationStatus.EVENT,
        stored=True,
        safetyEvent=record,
    )
