"""Tests for the AI Vision cross-process Safety Event client."""
from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from ai_vision.pipelines.backend_safety_event_client import (
    BackendConnectionError,
    BackendInvalidResponse,
    BackendRequestTimeout,
    BackendSafetyEventClient,
    BackendServerError,
    BackendValidationError,
)
from ai_vision.pipelines.detection_result import DetectionResult
from ai_vision.pipelines.safety_interpreter import SafetyInterpreter


_ROOT = Path(__file__).resolve().parents[3]
_FIXTURE = _ROOT / "ai_vision" / "pipelines" / "fixtures" / "mock_detection_results.json"


@pytest.fixture(scope="module")
def interpretations():
    raw = json.loads(_FIXTURE.read_text(encoding="utf-8"))
    interpreter = SafetyInterpreter()
    return [interpreter.interpret(DetectionResult.from_dict(item)) for item in raw["results"]]


def _event_response() -> dict:
    return {
        "status": "event",
        "stored": True,
        "safetyEvent": {
            "eventId": "safety-1",
            "eventType": "VISION_INTERPRETATION",
            "source": "ai_vision_mock",
            "userId": None,
            "stopId": None,
            "routeId": None,
            "confidence": 0.71,
            "message": "안내 메시지",
            "metadata": {"reason": "bus_door_visible"},
            "timestamp": "2026-05-22T00:00:00Z",
            "createdAt": "2026-05-22T00:00:01Z",
        },
    }


def test_client_sends_event_and_returns_backend_event_id(interpretations) -> None:
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.method == "POST"
        assert request.url.path == "/ai-vision/events"
        payload = json.loads(request.content)
        assert payload["status"] == "event"
        assert payload["modelInfo"]["provider"] == "mock"
        assert "detections" not in payload
        return httpx.Response(201, json=_event_response())

    with BackendSafetyEventClient(
        "http://localhost:8000", transport=httpx.MockTransport(handler)
    ) as client:
        result = client.send(interpretations[0])

    assert result.status == "event"
    assert result.stored is True
    assert result.event_id == "safety-1"
    assert len(requests) == 1


@pytest.mark.parametrize("index,status", [(1, "no_event"), (2, "unavailable"), (3, "error")])
def test_client_reports_non_event_statuses_without_storage(interpretations, index, status) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        assert payload["status"] == status
        assert "riskLevel" not in payload
        return httpx.Response(200, json={"status": status, "stored": False, "safetyEvent": None})

    with BackendSafetyEventClient(
        "http://localhost:8000", transport=httpx.MockTransport(handler)
    ) as client:
        result = client.send(interpretations[index])

    assert result.status == status
    assert result.stored is False
    assert result.event_id is None


@pytest.mark.parametrize(
    "status,exception",
    [(422, BackendValidationError), (503, BackendServerError)],
)
def test_client_distinguishes_backend_http_errors(interpretations, status, exception) -> None:
    transport = httpx.MockTransport(lambda _: httpx.Response(status, text="rejected"))
    with BackendSafetyEventClient("http://localhost:8000", transport=transport) as client:
        with pytest.raises(exception) as error:
            client.send(interpretations[0])
    assert error.value.status_code == status


def test_client_rejects_inconsistent_response(interpretations) -> None:
    transport = httpx.MockTransport(
        lambda _: httpx.Response(
            201,
            json={"status": "event", "stored": False, "safetyEvent": None},
        )
    )
    with BackendSafetyEventClient("http://localhost:8000", transport=transport) as client:
        with pytest.raises(BackendInvalidResponse, match="Stored event"):
            client.send(interpretations[0])


def test_client_classifies_connection_error(interpretations) -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    with BackendSafetyEventClient(
        "http://localhost:8000", transport=httpx.MockTransport(handler)
    ) as client:
        with pytest.raises(BackendConnectionError):
            client.send(interpretations[0])


def test_client_classifies_request_timeout(interpretations) -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out")

    with BackendSafetyEventClient(
        "http://localhost:8000", transport=httpx.MockTransport(handler)
    ) as client:
        with pytest.raises(BackendRequestTimeout):
            client.send(interpretations[0])


def test_client_reads_existing_recent_safety_event_endpoint() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "GET"
        assert request.url.path == "/safety-events/recent"
        assert request.url.params["limit"] == "5"
        return httpx.Response(200, json={"events": [{"eventId": "safety-1"}]})

    with BackendSafetyEventClient(
        "http://localhost:8000", transport=httpx.MockTransport(handler)
    ) as client:
        assert client.recent_events(limit=5) == [{"eventId": "safety-1"}]
