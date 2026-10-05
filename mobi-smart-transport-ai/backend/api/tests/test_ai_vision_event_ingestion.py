"""Transport endpoint to existing SafetyEventService integration tests."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path

import httpx
import pytest
from fastapi import Response
from jsonschema import Draft202012Validator, FormatChecker
from pydantic import ValidationError

from ai_vision.pipelines.backend_safety_event_client import (
    BackendSafetyEventClient,
    serialize_interpretation,
)
from ai_vision.pipelines.detection_result import DetectionResult
from ai_vision.pipelines.mock_vision_provider import MockScenario, MockVisionProvider
from ai_vision.pipelines.safety_interpreter import SafetyInterpreter
from ai_vision.pipelines.vision_input import VisionInferenceRequest, VisionInputSource
from ai_vision.pipelines.vision_safety_pipeline import VisionSafetyPipeline
from app.api.routes import ai_vision_events, safety_events
from app.main import app
from app.schemas.ai_vision_safety_event import AiVisionInterpretationIngestRequest
from app.services.firebase_client import FirebaseClient, FirebaseSettings
from app.services.safety_event_service import SafetyEventService


_ROOT = Path(__file__).resolve().parents[3]
_FIXTURE = _ROOT / "ai_vision" / "pipelines" / "fixtures" / "mock_detection_results.json"
_REQUEST_SCHEMA_PATH = (
    _ROOT / "packages" / "shared_contracts" / "api"
    / "ai_vision_safety_interpretation.request.schema.json"
)
_RESPONSE_SCHEMA_PATH = (
    _ROOT / "packages" / "shared_contracts" / "api"
    / "ai_vision_safety_interpretation.response.schema.json"
)


@pytest.fixture(scope="module")
def interpretations():
    raw = json.loads(_FIXTURE.read_text(encoding="utf-8"))
    interpreter = SafetyInterpreter()
    return [interpreter.interpret(DetectionResult.from_dict(item)) for item in raw["results"]]


@pytest.fixture
def isolated_service(monkeypatch):
    firebase = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    service = SafetyEventService(firebase)
    monkeypatch.setattr(ai_vision_events, "_service", service)
    return service


def _validate_schema(path: Path, instance: dict) -> None:
    schema = json.loads(path.read_text(encoding="utf-8"))
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(instance)


def test_detection_fixture_crosses_http_contract_endpoint_and_service(
    interpretations, isolated_service
) -> None:
    interpretation = interpretations[0]
    request = serialize_interpretation(interpretation)
    _validate_schema(_REQUEST_SCHEMA_PATH, request)
    payload = AiVisionInterpretationIngestRequest.model_validate(request)
    response = Response()

    result = ai_vision_events.ingest_ai_vision_interpretation(payload, response)
    response_body = result.model_dump(mode="json")
    _validate_schema(_RESPONSE_SCHEMA_PATH, response_body)

    assert response.status_code == 201
    assert response_body["status"] == "event"
    assert response_body["stored"] is True
    record = response_body["safetyEvent"]
    assert record["eventType"] == "VISION_INTERPRETATION"
    assert record["source"] == "ai_vision_mock"
    assert record["confidence"] == interpretation.event.confidence
    timestamp = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
    assert timestamp.astimezone(timezone.utc).isoformat() == "2026-05-22T00:00:00+00:00"
    assert record["metadata"] == {
        "visionEventId": interpretation.event.event_id,
        "frameId": interpretation.frame_id,
        "riskLevel": interpretation.event.risk_level,
        "reason": interpretation.event.reason,
        "primaryClass": interpretation.event.primary_class,
        "inputSource": "mock",
        "inferenceMode": "mock",
        "modelProvider": "mock",
        "modelName": "fixture-detector",
        "modelVersion": "1.0.0",
    }
    assert len(isolated_service.recent().events) == 1


def test_pipeline_client_endpoint_storage_and_recent_lookup(monkeypatch) -> None:
    firebase = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    service = SafetyEventService(firebase)
    monkeypatch.setattr(ai_vision_events, "_service", service)
    monkeypatch.setattr(safety_events, "_service", service)
    http_calls: list[str] = []

    def dispatch(request: httpx.Request) -> httpx.Response:
        http_calls.append(request.method + " " + request.url.path)
        if request.method == "POST" and request.url.path == "/ai-vision/events":
            payload = AiVisionInterpretationIngestRequest.model_validate(
                json.loads(request.content)
            )
            response = Response()
            body = ai_vision_events.ingest_ai_vision_interpretation(payload, response)
            return httpx.Response(
                response.status_code,
                json=body.model_dump(mode="json"),
            )
        if request.method == "GET" and request.url.path == "/safety-events/recent":
            body = safety_events.list_recent_safety_events(limit=20)
            return httpx.Response(200, json=body.model_dump(mode="json"))
        return httpx.Response(404, json={"detail": "not found"})

    request = VisionInferenceRequest(
        frame_id="22222222-2222-4222-8222-222222222222",
        captured_at="2026-05-22T09:00:00+09:00",
        source=VisionInputSource.IMAGE_FILE,
        payload=Path(__file__).resolve(),
    )
    with BackendSafetyEventClient(
        "http://backend.test", transport=httpx.MockTransport(dispatch)
    ) as client:
        pipeline = VisionSafetyPipeline(
            MockVisionProvider(scenario=MockScenario.MULTIPLE_DETECTIONS),
            SafetyInterpreter(),
            client,
        )
        result = pipeline.run(request)
        recent = client.recent_events()

    assert result.interpretation.status.value == "event"
    assert result.backend_stored is True
    assert result.backend_event_id is not None
    assert [item["eventId"] for item in recent] == [result.backend_event_id]
    assert http_calls == ["POST /ai-vision/events", "GET /safety-events/recent"]
    stored = firebase.get(f"/safetyEvents/{result.backend_event_id}")
    assert stored["metadata"]["reason"] == result.interpretation.event.reason


@pytest.mark.parametrize("index,status", [(1, "no_event"), (2, "unavailable"), (3, "error")])
def test_non_event_statuses_return_success_without_persisting(
    interpretations, isolated_service, index, status
) -> None:
    request = serialize_interpretation(interpretations[index])
    _validate_schema(_REQUEST_SCHEMA_PATH, request)
    payload = AiVisionInterpretationIngestRequest.model_validate(request)
    response = Response()

    result = ai_vision_events.ingest_ai_vision_interpretation(payload, response)
    body = result.model_dump(mode="json")
    _validate_schema(_RESPONSE_SCHEMA_PATH, body)

    assert response.status_code == 200
    assert body == {"status": status, "stored": False, "safetyEvent": None}
    assert isolated_service.recent().events == []


def test_malformed_or_contradictory_request_is_rejected() -> None:
    with pytest.raises(ValidationError):
        AiVisionInterpretationIngestRequest.model_validate(
            {"schemaVersion": "1.0.0", "status": "error", "source": "mock"}
        )

    contradiction = {
        "schemaVersion": "1.0.0",
        "status": "no_event",
        "source": "mock",
        "frameId": "22222222-2222-4222-8222-222222222222",
        "capturedAt": "2026-05-22T09:00:00+09:00",
        "eventId": "11111111-1111-4111-8111-111111111111",
    }
    with pytest.raises(ValidationError):
        AiVisionInterpretationIngestRequest.model_validate(contradiction)


def test_new_route_is_additive_and_existing_safety_event_routes_remain() -> None:
    route_paths = {route.path for route in app.routes}
    assert "/ai-vision/events" in route_paths
    assert "/safety-events" in route_paths
    assert "/safety-events/recent" in route_paths
    assert callable(safety_events.create_safety_event)
