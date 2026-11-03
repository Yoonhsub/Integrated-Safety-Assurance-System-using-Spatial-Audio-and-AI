"""Map AI Vision interpretation results to the backend Safety Event contract."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING, Any

from app.schemas.safety_event import SafetyEventCreate, SafetyEventType

if TYPE_CHECKING:
    from ai_vision.pipelines.safety_interpreter import SafetyInterpretation
    from app.schemas.ai_vision_safety_event import AiVisionInterpretationIngestRequest


_SOURCE_BY_MODEL_PROVIDER = {
    "mock": ("ai_vision_mock", "mock"),
    "ultralytics": ("ai_vision_live", "live"),
}


class SafetyInterpretationAdapterError(ValueError):
    """An event interpretation cannot be represented by backend SafetyEventCreate."""


class UnsupportedVisionProviderError(SafetyInterpretationAdapterError):
    """The event's provider is not explicitly classified as mock or live."""


@dataclass(frozen=True)
class _BackendModelInfo:
    provider: str
    name: str
    version: str | None


@dataclass(frozen=True)
class _BackendSafetyEvent:
    event_id: str
    frame_id: str
    captured_at: str
    source: str
    risk_level: str
    reason: str
    primary_class: str
    confidence: float
    message: str
    model_info: _BackendModelInfo


@dataclass(frozen=True)
class _BackendSafetyInterpretation:
    status: str
    frame_id: str | None
    captured_at: str | None
    source: str
    event: _BackendSafetyEvent | None
    error: Any = None


class AiVisionSafetyEventAdapter:
    """Convert an AI Vision interpretation; it does not persist or send events."""

    def from_transport_request(
        self,
        request: AiVisionInterpretationIngestRequest,
    ) -> _BackendSafetyInterpretation:
        """Reconstitute the small backend-side interpretation domain projection."""
        status = _status_value(request.status)
        frame_id = str(request.frameId) if request.frameId is not None else None
        captured_at = request.capturedAt.isoformat() if request.capturedAt is not None else None
        error = request.error
        if status != "event":
            return _BackendSafetyInterpretation(
                status=status,
                frame_id=frame_id,
                captured_at=captured_at,
                source=request.source,
                event=None,
                error=error,
            )

        model = request.modelInfo
        return _BackendSafetyInterpretation(
            status=status,
            frame_id=frame_id,
            captured_at=captured_at,
            source=request.source,
            event=_BackendSafetyEvent(
                event_id=str(request.eventId),
                frame_id=str(request.frameId),
                captured_at=captured_at or "",
                source=request.source,
                risk_level=_status_value(request.riskLevel),
                reason=_status_value(request.reason),
                primary_class=_status_value(request.primaryClass),
                confidence=request.confidence,
                message=request.message or "",
                model_info=_BackendModelInfo(
                    provider=model.provider,
                    name=model.name,
                    version=model.version,
                ),
            ),
        )

    def to_safety_event_create(
        self,
        interpretation: SafetyInterpretation | _BackendSafetyInterpretation,
    ) -> SafetyEventCreate | None:
        """Return a backend payload for event status, or None for non-event statuses.

        ``no_event``, ``unavailable`` and ``error`` are deliberately skipped so an
        inference failure cannot be persisted as a normal safety event.
        """
        try:
            status = _status_value(interpretation.status)
        except AttributeError as exc:
            raise SafetyInterpretationAdapterError(
                "SafetyInterpretation must provide a status."
            ) from exc

        if status in {"no_event", "unavailable", "error"}:
            if interpretation.event is not None:
                raise SafetyInterpretationAdapterError(
                    f"A {status} interpretation must not contain an event."
                )
            return None
        if status != "event":
            raise SafetyInterpretationAdapterError(
                f"Unsupported SafetyInterpretation status: {status!r}."
            )

        event = interpretation.event
        if event is None:
            raise SafetyInterpretationAdapterError(
                "An event interpretation must contain a Safety Event."
            )

        try:
            frame_id = _required_text(event.frame_id, "frameId")
            event_id = _required_text(event.event_id, "eventId")
            captured_at = _required_text(event.captured_at, "capturedAt")
            reason = _required_text(event.reason, "reason")
            primary_class = _required_text(event.primary_class, "primaryClass")
            risk_level = _required_text(event.risk_level, "riskLevel")
            input_source = _required_text(event.source, "source")
            confidence = event.confidence
            message = _required_text(event.message, "message")
            model_info = event.model_info
            model_provider = _required_text(model_info.provider, "modelInfo.provider")
            model_name = _required_text(model_info.name, "modelInfo.name")
        except AttributeError as exc:
            raise SafetyInterpretationAdapterError(
                "Safety Event is missing required fields or modelInfo."
            ) from exc

        if (
            interpretation.frame_id != frame_id
            or interpretation.captured_at != captured_at
            or interpretation.source != input_source
        ):
            raise SafetyInterpretationAdapterError(
                "SafetyInterpretation metadata must match its contained Safety Event."
            )
        if risk_level not in {"info", "warn", "danger"}:
            raise SafetyInterpretationAdapterError(
                f"Unsupported AI Vision riskLevel: {risk_level!r}."
            )
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
            raise SafetyInterpretationAdapterError("Safety Event confidence must be numeric.")
        if not 0 <= confidence <= 1:
            raise SafetyInterpretationAdapterError("Safety Event confidence must be in [0, 1].")

        source_mapping = _SOURCE_BY_MODEL_PROVIDER.get(model_provider)
        if source_mapping is None:
            raise UnsupportedVisionProviderError(
                f"AI Vision provider {model_provider!r} has no explicit mock/live source mapping."
            )
        source, inference_mode = source_mapping

        metadata = {
            "visionEventId": event_id,
            "frameId": frame_id,
            "riskLevel": risk_level,
            "reason": reason,
            "primaryClass": primary_class,
            "inputSource": input_source,
            "inferenceMode": inference_mode,
            "modelProvider": model_provider,
            "modelName": model_name,
        }
        model_version = getattr(model_info, "version", None)
        if model_version:
            metadata["modelVersion"] = str(model_version)

        try:
            timestamp = datetime.fromisoformat(captured_at.replace("Z", "+00:00"))
        except (TypeError, ValueError) as exc:
            raise SafetyInterpretationAdapterError(
                "Safety Event capturedAt must be a valid timezone-aware ISO 8601 timestamp."
            ) from exc
        if timestamp.tzinfo is None or timestamp.utcoffset() is None:
            raise SafetyInterpretationAdapterError(
                "Safety Event capturedAt must include a timezone."
            )

        return SafetyEventCreate(
            eventType=SafetyEventType.VISION_INTERPRETATION,
            source=source,
            confidence=float(confidence),
            message=message,
            metadata=metadata,
            timestamp=timestamp,
        )


def _status_value(value: Any) -> str:
    raw = getattr(value, "value", value)
    if not isinstance(raw, str):
        raise AttributeError("status must be a string or enum value")
    return raw


def _required_text(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SafetyInterpretationAdapterError(
            f"Safety Event {field_name} must be a non-blank string."
        )
    return value
