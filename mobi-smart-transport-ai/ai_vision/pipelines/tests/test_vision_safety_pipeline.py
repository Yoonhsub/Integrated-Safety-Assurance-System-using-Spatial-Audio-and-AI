"""Tests for the single-request VisionSafetyPipeline orchestration."""
from __future__ import annotations

import json
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import pytest

from ai_vision.pipelines.backend_safety_event_client import (
    BackendConnectionError,
    BackendSafetyEventOutcome,
)
from ai_vision.pipelines.detection_result import DetectionResult, DetectionStatus
from ai_vision.pipelines.mock_vision_provider import MockScenario, MockVisionProvider
from ai_vision.pipelines.safety_interpreter import (
    InterpretationStatus,
    SafetyInterpretation,
    SafetyInterpreter,
)
from ai_vision.pipelines.vision_input import VisionInferenceRequest, VisionInputSource
from ai_vision.pipelines.vision_safety_pipeline import VisionSafetyPipeline


_FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "fixtures"
    / "mock_detection_results.json"
)


def _request() -> VisionInferenceRequest:
    return VisionInferenceRequest(
        frame_id=str(uuid4()),
        captured_at=datetime.now(timezone.utc).isoformat(),
        source=VisionInputSource.IMAGE_FILE,
        # MockVisionProvider validates request metadata but does not read image bytes.
        payload=Path(__file__).resolve(),
    )


class RecordingClient:
    def __init__(self, *, fail: Exception | None = None) -> None:
        self.calls: list[tuple[str, object]] = []
        self.fail = fail

    def send(self, interpretation: SafetyInterpretation) -> BackendSafetyEventOutcome:
        self.calls.append(("send", interpretation))
        if self.fail is not None:
            raise self.fail
        stored = interpretation.status is InterpretationStatus.EVENT
        return BackendSafetyEventOutcome(
            status=interpretation.status.value,
            stored=stored,
            event_id="safety-event-1" if stored else None,
        )


class RecordingProvider:
    def __init__(self, result: DetectionResult, calls: list[tuple[str, object]]) -> None:
        self.result = result
        self.calls = calls

    def infer(self, request: VisionInferenceRequest) -> DetectionResult:
        self.calls.append(("infer", request))
        return replace(self.result, frame_id=request.frame_id, captured_at=request.captured_at)


class RecordingInterpreter:
    def __init__(self, calls: list[tuple[str, object]]) -> None:
        self.calls = calls

    def interpret(self, result: DetectionResult) -> SafetyInterpretation:
        self.calls.append(("interpret", result))
        return SafetyInterpretation(
            status=InterpretationStatus.NO_EVENT,
            frame_id=result.frame_id,
            captured_at=result.captured_at,
            source=result.source,
        )


def _fixture_result(status: str = "ok", *, empty: bool = False) -> DetectionResult:
    payload = json.loads(_FIXTURE.read_text(encoding="utf-8"))
    item = next(
        result
        for result in payload["results"]
        if result["status"] == status
        and (not empty or not result.get("detections"))
    )
    return DetectionResult.from_dict(item)


def test_pipeline_calls_provider_interpreter_then_backend_in_order() -> None:
    calls: list[tuple[str, object]] = []
    result = _fixture_result()
    provider = RecordingProvider(result, calls)
    interpreter = RecordingInterpreter(calls)

    class Client(RecordingClient):
        def send(self, interpretation: SafetyInterpretation) -> BackendSafetyEventOutcome:
            self.calls.append(("send", interpretation))
            calls.append(("send", interpretation))
            return BackendSafetyEventOutcome("no_event", False, None)

    client = Client()
    pipeline = VisionSafetyPipeline(provider, interpreter, client)  # type: ignore[arg-type]
    request = _request()

    response = pipeline.run(request)

    assert [name for name, _ in calls] == ["infer", "interpret", "send"]
    assert calls[0][1] is request
    assert calls[1][1] is response.detection_result
    assert calls[2][1] is response.interpretation
    assert response.detection_result.frame_id == request.frame_id
    assert response.detection_result.captured_at == request.captured_at


def test_fixture_event_is_sent_and_backend_storage_is_reported() -> None:
    request = _request()
    client = RecordingClient()
    pipeline = VisionSafetyPipeline(
        MockVisionProvider(scenario=MockScenario.MULTIPLE_DETECTIONS),
        SafetyInterpreter(),
        client,  # type: ignore[arg-type]
    )

    result = pipeline.run(request)

    assert result.detection_status is DetectionStatus.OK
    assert result.detection_count == 2
    assert result.detected_classes == ("bus", "bus_door")
    assert result.interpretation_status is InterpretationStatus.EVENT
    assert result.event_detected is True
    assert result.backend_sent is True
    assert result.backend_stored is True
    assert result.backend_event_id == "safety-event-1"
    assert result.detection_result.frame_id == request.frame_id
    assert result.detection_result.captured_at == request.captured_at


@pytest.mark.parametrize(
    "scenario,status",
    [
        (MockScenario.EMPTY, InterpretationStatus.NO_EVENT),
        (MockScenario.UNAVAILABLE, InterpretationStatus.UNAVAILABLE),
        (MockScenario.ERROR, InterpretationStatus.ERROR),
    ],
)
def test_non_event_scenarios_are_transmitted_but_not_stored(scenario, status) -> None:
    client = RecordingClient()
    pipeline = VisionSafetyPipeline(
        MockVisionProvider(scenario=scenario),
        SafetyInterpreter(),
        client,  # type: ignore[arg-type]
    )

    result = pipeline.run(_request())

    assert result.interpretation_status is status
    assert result.event_detected is False
    assert result.backend_sent is True
    assert result.backend_stored is False
    assert result.backend_event_id is None
    assert client.calls[0][1] is result.interpretation


def test_backend_connection_error_is_not_converted_to_pipeline_success() -> None:
    error = BackendConnectionError("connection refused")
    pipeline = VisionSafetyPipeline(
        MockVisionProvider(scenario=MockScenario.EMPTY),
        SafetyInterpreter(),
        RecordingClient(fail=error),  # type: ignore[arg-type]
    )

    with pytest.raises(BackendConnectionError) as raised:
        pipeline.run(_request())

    assert raised.value is error
