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


@pytest.mark.parametrize("case,expected", [
    ("bus", "no_event"), ("multiple", "no_event"),
    ("person", "no_event"), ("empty", "no_event"),
    ("low_confidence", "no_event"), ("invalid_bbox", "error"),
    ("inference_failure", "error"),
])
def test_yolo_adapter_to_actual_asgi_route_offline(
    monkeypatch, tmp_path, case, expected
):
    """Fake detector output, real provider/interpreter/client/ASGI validation.

    This is deliberately NOT evidence of real YOLO inference or Firebase Auth.
    The existing test-only admin dependency and in-memory store are used.
    """
    from types import SimpleNamespace
    from fastapi.testclient import TestClient
    from ai_vision.pipelines.yolo_vision_provider import YOLOVisionProvider

    weights = tmp_path / "yolo11n.pt"
    weights.write_bytes(b"FAKE detector weights; never loaded by Ultralytics")
    image = tmp_path / "frame.jpg"
    image.write_bytes(b"FAKE image; injected detector does not read it")
    classes = [0] if case == "person" else [5]
    coordinates = [[180, 90, 20, 10]] if case == "invalid_bbox" else [[20, 10, 180, 90]]
    scores = [0.2] if case == "low_confidence" else [0.9]
    if case == "empty":
        classes, coordinates, scores = [], [], []
    elif case == "multiple":
        classes, coordinates, scores = [5, 0, 5], coordinates * 3, scores * 3

    class FakeDetector:
        def predict(self, **kwargs):
            if case == "inference_failure":
                raise RuntimeError("offline inference failure")
            return [SimpleNamespace(orig_shape=(100, 200), names={0: "person", 5: "bus"},
                boxes=SimpleNamespace(xyxy=coordinates, cls=classes, conf=scores))]

    firebase = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    service = SafetyEventService(firebase)
    monkeypatch.setattr(ai_vision_events, "_service", service)
    calls = []
    asgi = TestClient(app)

    def dispatch(request):
        assert (request.method, request.url.path) == ("POST", "/ai-vision/events")
        payload = json.loads(request.content)
        AiVisionInterpretationIngestRequest.model_validate(payload)
        calls.append(payload)
        response = asgi.post(request.url.path, json=payload)
        return httpx.Response(response.status_code, json=response.json())

    request = VisionInferenceRequest(
        frame_id="44444444-4444-4444-8444-444444444444",
        captured_at="2026-10-27T00:00:00Z",
        source=VisionInputSource.IMAGE_FILE, payload=image,
    )
    try:
        with BackendSafetyEventClient("http://backend.test", transport=httpx.MockTransport(dispatch)) as client:
            result = VisionSafetyPipeline(
                YOLOVisionProvider(weights, model_factory=lambda _: FakeDetector()),
                SafetyInterpreter(), client,
            ).run(request)
    finally:
        asgi.close()

    schema = _ROOT / "packages/shared_contracts/api/vision_detection.response.schema.json"
    _validate_schema(schema, result.detection_result.to_dict())
    assert len(calls) == 1  # No implicit retry, including model failure reports.
    assert result.interpretation.status.value == expected
    assert result.backend_sent is True and result.backend_stored is False
    assert result.backend_outcome.status == expected
    assert service.recent().events == []
    assert all(d.class_id == "bus" for d in result.detection_result.detections)
    if case == "multiple":
        assert len(result.detection_result.detections) == 2
    if expected == "error":
        assert result.detection_result.status.value == "error"


def test_legacy_event_duplicate_policy_is_not_implicit_idempotency(
    monkeypatch, interpretations, isolated_service
):
    """Two explicit legacy submissions store two records; never assume dedup."""
    from fastapi.testclient import TestClient
    with TestClient(app) as client:
        payload = serialize_interpretation(interpretations[0])
        first = client.post("/ai-vision/events", json=payload)
        second = client.post("/ai-vision/events", json=payload)
        assert first.status_code == second.status_code == 201
        a, b = first.json()["safetyEvent"], second.json()["safetyEvent"]
        assert a["eventId"] != b["eventId"]
        assert a["metadata"]["visionEventId"] == b["metadata"]["visionEventId"]
        assert len(isolated_service.recent().events) == 2
