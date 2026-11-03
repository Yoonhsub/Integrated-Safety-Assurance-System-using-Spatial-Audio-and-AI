"""Orchestrate one image request through vision, interpretation, and backend transport."""
from __future__ import annotations

from dataclasses import dataclass

from ai_vision.pipelines.backend_safety_event_client import (
    BackendSafetyEventClient,
    BackendSafetyEventOutcome,
)
from ai_vision.pipelines.detection_result import DetectionResult, DetectionStatus
from ai_vision.pipelines.safety_interpreter import (
    InterpretationStatus,
    SafetyInterpretation,
    SafetyInterpreter,
)
from ai_vision.pipelines.vision_input import VisionInferenceRequest
from ai_vision.pipelines.vision_provider import VisionProvider


@dataclass(frozen=True)
class VisionSafetyPipelineResult:
    """Summary and domain results from one completed pipeline execution."""

    detection_result: DetectionResult
    interpretation: SafetyInterpretation
    backend_outcome: BackendSafetyEventOutcome

    @property
    def detection_status(self) -> DetectionStatus:
        return self.detection_result.status

    @property
    def detection_count(self) -> int:
        return len(self.detection_result.detections)

    @property
    def detected_classes(self) -> tuple[str, ...]:
        """Unique project class IDs in their stable first-detected order."""
        return tuple(dict.fromkeys(item.class_id for item in self.detection_result.detections))

    @property
    def interpretation_status(self) -> InterpretationStatus:
        return self.interpretation.status

    @property
    def event_detected(self) -> bool:
        return self.interpretation.status is InterpretationStatus.EVENT

    @property
    def backend_sent(self) -> bool:
        # A result only exists after send() returned successfully.
        return True

    @property
    def backend_stored(self) -> bool:
        return self.backend_outcome.stored

    @property
    def backend_event_id(self) -> str | None:
        return self.backend_outcome.event_id


class VisionSafetyPipeline:
    """Connect the provider, interpreter, and transport without duplicating their logic."""

    def __init__(
        self,
        provider: VisionProvider,
        interpreter: SafetyInterpreter,
        backend_client: BackendSafetyEventClient,
    ) -> None:
        self.provider = provider
        self.interpreter = interpreter
        self.backend_client = backend_client

    def run(self, request: VisionInferenceRequest) -> VisionSafetyPipelineResult:
        """Run a single request and propagate provider/client exceptions unchanged."""
        detection_result = self.provider.infer(request)
        interpretation = self.interpreter.interpret(detection_result)
        # All statuses are transported. Backend policy stores only ``event``;
        # no_event/unavailable/error are acknowledged without creating events.
        backend_outcome = self.backend_client.send(interpretation)
        return VisionSafetyPipelineResult(
            detection_result=detection_result,
            interpretation=interpretation,
            backend_outcome=backend_outcome,
        )
