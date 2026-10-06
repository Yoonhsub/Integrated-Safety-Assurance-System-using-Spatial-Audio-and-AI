"""AI Vision to existing backend Safety Event service integration tests."""
from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

import pytest

from ai_vision.pipelines.detection_result import DetectionResult, DetectionStatus, ModelInfo
from ai_vision.pipelines.safety_interpreter import (
    InterpretationStatus,
    SafetyInterpretation,
    SafetyInterpreter,
)
from app.schemas.safety_event import SafetyEventCreate, SafetyEventType
from app.services.ai_vision_safety_event_adapter import (
    AiVisionSafetyEventAdapter,
    SafetyInterpretationAdapterError,
    UnsupportedVisionProviderError,
)
from app.services.firebase_client import FirebaseClient, FirebaseSettings
from app.services.safety_event_service import SafetyEventService


_ROOT = Path(__file__).resolve().parents[3]
_DETECTION_FIXTURE = _ROOT / "ai_vision" / "pipelines" / "fixtures" / "mock_detection_results.json"


@pytest.fixture
def vision_event():
    fixture = json.loads(_DETECTION_FIXTURE.read_text(encoding="utf-8"))
    result = DetectionResult.from_dict(fixture["results"][0])
    interpreted = SafetyInterpreter().interpret(result)
    assert interpreted.status is InterpretationStatus.EVENT
    return interpreted


def test_adapter_maps_event_and_metadata_to_backend_contract(vision_event) -> None:
    payload = AiVisionSafetyEventAdapter().to_safety_event_create(vision_event)

    assert isinstance(payload, SafetyEventCreate)
    assert payload.eventType is SafetyEventType.VISION_INTERPRETATION
    assert payload.source == "ai_vision_mock"
    assert payload.confidence == vision_event.event.confidence
    assert payload.message == vision_event.event.message
    assert payload.timestamp.isoformat() == "2026-05-22T00:00:00+00:00"
    assert payload.metadata == {
        "visionEventId": vision_event.event.event_id,
        "frameId": vision_event.frame_id,
        "riskLevel": "info",
        "reason": "bus_door_visible",
        "primaryClass": "bus_door",
        "inputSource": "mock",
        "inferenceMode": "mock",
        "modelProvider": "mock",
        "modelName": "fixture-detector",
        "modelVersion": "1.0.0",
    }
    assert all(isinstance(key, str) and isinstance(value, str) for key, value in payload.metadata.items())


def test_adapter_preserves_non_info_risk_in_metadata(vision_event) -> None:
    event = replace(vision_event.event, risk_level="warn")
    payload = AiVisionSafetyEventAdapter().to_safety_event_create(
        replace(vision_event, event=event)
    )
    assert payload.metadata["riskLevel"] == "warn"


def test_adapter_distinguishes_live_yolo_from_mock(vision_event) -> None:
    model = ModelInfo(provider="ultralytics", name="yolo11n", version="8.3.0")
    event = replace(vision_event.event, model_info=model)
    payload = AiVisionSafetyEventAdapter().to_safety_event_create(
        replace(vision_event, event=event)
    )
    assert payload.source == "ai_vision_live"
    assert payload.metadata["inferenceMode"] == "live"
    assert payload.metadata["modelProvider"] == "ultralytics"


@pytest.mark.parametrize("status", ["no_event", "unavailable", "error"])
def test_non_event_statuses_are_not_converted_or_persisted(status: str) -> None:
    fixture = json.loads(_DETECTION_FIXTURE.read_text(encoding="utf-8"))
    results = {item["status"]: item for item in fixture["results"]}
    if status == "no_event":
        empty_result = next(
            item for item in fixture["results"]
            if item["status"] == "ok" and not item["detections"]
        )
        result = DetectionResult.from_dict(empty_result)
    else:
        result = DetectionResult.from_dict(results[status])
    interpretation = SafetyInterpreter().interpret(result)

    firebase = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    service = SafetyEventService(firebase)
    payload = AiVisionSafetyEventAdapter().to_safety_event_create(interpretation)
    if payload is not None:
        service.create(payload)

    assert payload is None
    assert service.recent().events == []


def test_malformed_event_interpretation_is_rejected(vision_event) -> None:
    adapter = AiVisionSafetyEventAdapter()
    with pytest.raises(SafetyInterpretationAdapterError, match="must contain"):
        adapter.to_safety_event_create(replace(vision_event, event=None))


def test_mismatched_interpretation_metadata_is_rejected(vision_event) -> None:
    with pytest.raises(SafetyInterpretationAdapterError, match="must match"):
        AiVisionSafetyEventAdapter().to_safety_event_create(
            replace(vision_event, frame_id="different-frame")
        )


def test_unknown_provider_does_not_fall_back_to_mock(vision_event) -> None:
    event = replace(
        vision_event.event,
        model_info=ModelInfo(provider="unknown", name="mystery-model"),
    )
    with pytest.raises(UnsupportedVisionProviderError):
        AiVisionSafetyEventAdapter().to_safety_event_create(
            replace(vision_event, event=event)
        )


def test_detection_fixture_to_interpreter_adapter_and_existing_service(vision_event) -> None:
    firebase = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    service = SafetyEventService(firebase)
    payload = AiVisionSafetyEventAdapter().to_safety_event_create(vision_event)
    assert payload is not None

    created = service.create(payload)
    recent = service.recent().events
    stored = firebase.get(f"/safetyEvents/{created.eventId}")

    assert len(recent) == 1
    assert recent[0] == created
    assert stored["eventType"] == "VISION_INTERPRETATION"
    assert stored["source"] == "ai_vision_mock"
    assert stored["metadata"]["reason"] == "bus_door_visible"
    assert stored["metadata"]["frameId"] == vision_event.frame_id


def test_existing_backend_event_types_remain_valid() -> None:
    payload = SafetyEventCreate(eventType="OBSTACLE_DETECTED", source="sensor_mock")
    assert payload.eventType is SafetyEventType.OBSTACLE_DETECTED


def test_interpreter_failure_status_is_preserved_before_adapter_skip() -> None:
    result = DetectionResult(
        schema_version="1.0.0",
        source="image_file",
        status=DetectionStatus.ERROR,
        detections=(),
    )
    interpretation = SafetyInterpreter().interpret(result)
    assert interpretation.status is InterpretationStatus.ERROR
    assert AiVisionSafetyEventAdapter().to_safety_event_create(interpretation) is None
