"""실시간 안내 후보 안정화 규칙 검증."""

from __future__ import annotations

import sys
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from guidance_stability import GuidanceStabilityPolicy, GuidanceStabilizer  # noqa: E402
from spatial_guidance import interpret_bus_door_guidance, interpret_bus_guidance  # noqa: E402
from vision_result import ImageSize, RawDetection, build_vision_result  # noqa: E402


class GuidanceStabilityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.started_at = datetime(2026, 10, 25, 9, 0, tzinfo=timezone.utc)
        self.stabilizer = GuidanceStabilizer()

    def result(self, seconds: int, detections: list[RawDetection]):
        return build_vision_result(
            frame_id=str(uuid.uuid4()),
            captured_at=self.started_at + timedelta(seconds=seconds),
            image_size=ImageSize(width=1000, height=1000),
            raw_detections=detections,
            model_name="yolov11n",
            model_version="test",
            thresholds={"bus": 0.50, "bus_door": 0.55},
        )

    def bus_candidate(self, seconds: int, *, left: int = 350, right: int = 650):
        result = self.result(seconds, [RawDetection("bus", 0.90, left, 100, right, 500)])
        candidate = interpret_bus_guidance(result)
        assert candidate is not None
        return result, candidate

    def test_requires_three_consecutive_directions(self) -> None:
        for second in (0, 1):
            result, candidate = self.bus_candidate(second)
            self.assertEqual(self.stabilizer.filter((candidate,), captured_at=result.captured_at), ())

        result, candidate = self.bus_candidate(2)
        selected = self.stabilizer.filter((candidate,), captured_at=result.captured_at)
        self.assertEqual([item.class_id for item in selected], ["bus"])

    def test_direction_jitter_restarts_confirmation(self) -> None:
        for second, left, right in ((0, 20, 260), (1, 20, 260), (2, 350, 650), (3, 350, 650)):
            result, candidate = self.bus_candidate(second, left=left, right=right)
            self.assertEqual(self.stabilizer.filter((candidate,), captured_at=result.captured_at), ())

        result, candidate = self.bus_candidate(4)
        self.assertEqual(self.stabilizer.filter((candidate,), captured_at=result.captured_at)[0].direction.value, "CENTER")

    def test_suppresses_same_candidate_during_cooldown(self) -> None:
        for second in (0, 1, 2):
            result, candidate = self.bus_candidate(second)
            selected = self.stabilizer.filter((candidate,), captured_at=result.captured_at)
        self.assertEqual(len(selected), 1)

        result, candidate = self.bus_candidate(3)
        self.assertEqual(self.stabilizer.filter((candidate,), captured_at=result.captured_at), ())
        result, candidate = self.bus_candidate(6)
        self.assertEqual(len(self.stabilizer.filter((candidate,), captured_at=result.captured_at)), 1)

    def test_prioritizes_door_over_bus(self) -> None:
        stabilizer = GuidanceStabilizer(GuidanceStabilityPolicy(confirmation_frames=1))
        result = self.result(
            0,
            [
                RawDetection("bus", 0.90, 200, 100, 900, 900),
                RawDetection("bus_door", 0.80, 650, 300, 800, 800),
            ],
        )
        bus = interpret_bus_guidance(result)
        door = interpret_bus_door_guidance(result)
        assert bus is not None and door is not None
        selected = stabilizer.filter((bus, door), captured_at=result.captured_at)
        self.assertEqual([item.class_id for item in selected], ["bus_door"])


if __name__ == "__main__":
    unittest.main()
