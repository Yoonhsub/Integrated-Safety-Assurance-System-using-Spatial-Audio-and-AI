"""화면 위치·상대 거리·접근 상태 해석 규칙 검증."""

from __future__ import annotations

import sys
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from spatial_guidance import (  # noqa: E402
    MotionState,
    RelativeDistance,
    ScreenDirection,
    interpret_bus_guidance,
)
from vision_result import ImageSize, RawDetection, build_vision_result  # noqa: E402


class SpatialGuidanceTest(unittest.TestCase):
    def result(self, detections: list[RawDetection]):
        return build_vision_result(
            frame_id=str(uuid.uuid4()),
            captured_at=datetime(2026, 10, 4, 12, 0, tzinfo=timezone.utc),
            image_size=ImageSize(width=1000, height=1000),
            raw_detections=detections,
            model_name="yolov11n",
            model_version="test",
            thresholds={"bus": 0.50},
        )

    def test_interprets_left_far_bus_without_previous_frame(self) -> None:
        current = self.result([RawDetection("bus", 0.90, 50, 100, 150, 300)])

        guidance = interpret_bus_guidance(current)

        self.assertIsNotNone(guidance)
        assert guidance is not None
        self.assertEqual(guidance.direction, ScreenDirection.LEFT)
        self.assertEqual(guidance.relative_distance, RelativeDistance.FAR)
        self.assertEqual(guidance.motion, MotionState.UNKNOWN)
        self.assertEqual(guidance.as_dict()["relativeDistance"], "FAR")

    def test_interprets_center_medium_bus_and_approach(self) -> None:
        previous = self.result([RawDetection("bus", 0.90, 400, 100, 600, 400)])
        current = self.result([RawDetection("bus", 0.90, 350, 100, 650, 500)])

        guidance = interpret_bus_guidance(current, previous)

        assert guidance is not None
        self.assertEqual(guidance.direction, ScreenDirection.CENTER)
        self.assertEqual(guidance.relative_distance, RelativeDistance.MEDIUM)
        self.assertEqual(guidance.motion, MotionState.APPROACHING)

    def test_uses_largest_bus_and_marks_near_receding(self) -> None:
        previous = self.result([RawDetection("bus", 0.90, 100, 100, 800, 800)])
        current = self.result(
            [
                RawDetection("bus", 0.99, 20, 20, 80, 80),
                RawDetection("bus", 0.70, 150, 100, 650, 600),
            ]
        )

        guidance = interpret_bus_guidance(current, previous)

        assert guidance is not None
        self.assertEqual(guidance.direction, ScreenDirection.CENTER)
        self.assertEqual(guidance.relative_distance, RelativeDistance.NEAR)
        self.assertEqual(guidance.motion, MotionState.RECEDING)

    def test_returns_none_when_current_frame_has_no_bus(self) -> None:
        current = self.result([])

        self.assertIsNone(interpret_bus_guidance(current))


if __name__ == "__main__":
    unittest.main()
