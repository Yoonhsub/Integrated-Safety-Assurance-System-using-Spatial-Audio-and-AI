"""Tests for deterministic taxonomy-based single-frame safety interpretation."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

from ai_vision.pipelines.detection_result import (
    BoundingBox,
    Detection,
    DetectionError,
    DetectionResult,
    DetectionStatus,
    ImageSize,
    ModelInfo,
)
from ai_vision.pipelines.mock_inference_pipeline import get_all_events
from ai_vision.pipelines.safety_interpreter import (
    InterpretationStatus,
    SafetyInterpreter,
)


_PIPELINES = Path(__file__).resolve().parents[1]
_RESULTS_PATH = _PIPELINES / "fixtures" / "mock_detection_results.json"


class SafetyInterpreterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.interpreter = SafetyInterpreter()
        self.frame_id = "44444444-4444-4444-8444-444444444444"
        self.captured_at = "2026-05-22T09:00:05+09:00"
        self.model_info = ModelInfo(provider="mock", name="fixture-detector", version="1.0.0")

    def detection(self, class_id: str, confidence: float, *, x: float = 0.2) -> Detection:
        names = {
            "bus": "버스",
            "bus_door": "버스 문",
            "bus_stop": "버스 정류장",
            "roadway": "차도",
            "sidewalk": "보도",
            "obstacle": "장애물",
            "tactile_paving": "점자블록",
        }
        return Detection(
            class_id=class_id,
            class_name=names.get(class_id, "unknown"),
            confidence=confidence,
            bbox=BoundingBox(x=x, y=0.3, w=0.2, h=0.2),
        )

    def result(self, *detections: Detection) -> DetectionResult:
        return DetectionResult(
            schema_version="1.0.0",
            source="image_file",
            status=DetectionStatus.OK,
            frame_id=self.frame_id,
            captured_at=self.captured_at,
            image_size=ImageSize(width=640, height=480),
            model_info=self.model_info,
            detections=tuple(detections),
        )

    def test_valid_detection_creates_taxonomy_backed_safety_event(self) -> None:
        result = self.result(self.detection("bus_door", 0.71))
        interpreted = self.interpreter.interpret(result)

        self.assertEqual(interpreted.status, InterpretationStatus.EVENT)
        self.assertEqual(interpreted.event.reason, "bus_door_visible")
        self.assertEqual(interpreted.event.risk_level, "info")
        self.assertEqual(interpreted.event.primary_class, "bus_door")
        self.assertEqual(interpreted.event.message, "버스 문이 보입니다. 안전하게 승차할 수 있습니다.")

    def test_detection_below_taxonomy_threshold_produces_no_event(self) -> None:
        result = self.result(self.detection("bus_door", 0.549))
        self.assertEqual(self.interpreter.interpret(result).status, InterpretationStatus.NO_EVENT)

    def test_taxonomy_threshold_boundary_is_inclusive(self) -> None:
        result = self.result(self.detection("bus_door", 0.55))
        self.assertEqual(self.interpreter.interpret(result).status, InterpretationStatus.EVENT)

    def test_multiple_candidates_choose_highest_confidence_deterministically(self) -> None:
        result = self.result(
            self.detection("bus_stop", 0.83),
            self.detection("bus_door", 0.71),
        )
        first = self.interpreter.interpret(result)
        second = self.interpreter.interpret(result)

        self.assertEqual(first.event.primary_class, "bus_stop")
        self.assertEqual(first.event.event_id, second.event.event_id)
        self.assertEqual(first.event.to_dict(), second.event.to_dict())

    def test_empty_detection_is_normal_no_event(self) -> None:
        interpreted = self.interpreter.interpret(self.result())
        self.assertEqual(interpreted.status, InterpretationStatus.NO_EVENT)
        self.assertIsNone(interpreted.event)

    def test_unavailable_is_not_interpreted_as_no_event(self) -> None:
        result = DetectionResult(
            schema_version="1.0.0",
            source="webcam",
            status=DetectionStatus.UNAVAILABLE,
            detections=(),
            error=DetectionError("SOURCE_UNAVAILABLE", "No frame source is available."),
        )
        interpreted = self.interpreter.interpret(result)
        self.assertEqual(interpreted.status, InterpretationStatus.UNAVAILABLE)
        self.assertEqual(interpreted.error, result.error)
        self.assertIsNone(interpreted.event)

    def test_error_is_not_interpreted_as_no_event(self) -> None:
        result = DetectionResult(
            schema_version="1.0.0",
            source="mock",
            status=DetectionStatus.ERROR,
            detections=(),
            error=DetectionError("INFERENCE_FAILED", "Inference failed."),
        )
        interpreted = self.interpreter.interpret(result)
        self.assertEqual(interpreted.status, InterpretationStatus.ERROR)
        self.assertEqual(interpreted.error, result.error)
        self.assertIsNone(interpreted.event)

    def test_bus_detection_alone_does_not_become_high_risk_event(self) -> None:
        interpreted = self.interpreter.interpret(self.result(self.detection("bus", 0.88)))
        self.assertEqual(interpreted.status, InterpretationStatus.NO_EVENT)
        self.assertIsNone(interpreted.event)

    def test_mock_project_specific_detection_is_interpreted(self) -> None:
        fixture = json.loads(_RESULTS_PATH.read_text(encoding="utf-8"))
        result = DetectionResult.from_dict(fixture["results"][0])
        interpreted = self.interpreter.interpret(result)

        self.assertEqual(interpreted.status, InterpretationStatus.EVENT)
        self.assertEqual(interpreted.event.primary_class, "bus_door")
        # A single frame cannot establish the fixture's separate approaching_bus context.
        self.assertNotEqual(interpreted.event.reason, "approaching_bus")

    def test_deterministic_primary_uses_taxonomy_priority_before_confidence(self) -> None:
        # The present one-frame rules have equal (high) taxonomy priority, so confidence
        # is the next tie-breaker. Reversing input order must not change the selection.
        detections = (self.detection("bus_door", 0.71), self.detection("bus_stop", 0.83))
        forward = self.interpreter.interpret(self.result(*detections))
        reverse = self.interpreter.interpret(self.result(*reversed(detections)))
        self.assertEqual(forward.event.primary_class, reverse.event.primary_class)
        self.assertEqual(forward.event.to_dict(), reverse.event.to_dict())

    def test_event_preserves_request_metadata_and_detector_summary(self) -> None:
        result = self.result(self.detection("bus_door", 0.71))
        event = self.interpreter.interpret(result).event
        self.assertEqual(event.frame_id, result.frame_id)
        self.assertEqual(event.captured_at, result.captured_at)
        self.assertEqual(event.source, result.source)
        self.assertEqual(event.confidence, result.detections[0].confidence)
        self.assertEqual(event.image_size, result.image_size)
        self.assertEqual(event.model_info, result.model_info)
        self.assertEqual(event.to_dict()["detections"][0]["score"], 0.71)

    def test_unknown_class_is_ignored_without_safety_claim(self) -> None:
        interpreted = self.interpreter.interpret(self.result(self.detection("alien", 0.99)))
        self.assertEqual(interpreted.status, InterpretationStatus.NO_EVENT)
        self.assertIsNone(interpreted.event)

    def test_ok_result_missing_required_metadata_is_rejected(self) -> None:
        result = DetectionResult(
            schema_version="1.0.0",
            source="mock",
            status=DetectionStatus.OK,
            detections=(),
        )
        with self.assertRaises(ValueError):
            self.interpreter.interpret(result)

    def test_historical_mock_safety_events_remain_unchanged_and_loadable(self) -> None:
        events = get_all_events()
        self.assertEqual(len(events), 4)
        self.assertEqual(
            [event["reason"] for event in events],
            ["bus_stop_recognized", "approaching_bus", "off_sidewalk", "tactile_paving_lost"],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
