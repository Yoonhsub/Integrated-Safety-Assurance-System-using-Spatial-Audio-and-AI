"""AI Vision 안내 후보 전달 payload 검증."""

from __future__ import annotations

import json
import sys
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from guidance_handoff import PROPOSED_SCHEMA_VERSION, build_vision_guidance_handoff  # noqa: E402
from vision_result import ImageSize, RawDetection, build_vision_result  # noqa: E402


class GuidanceHandoffTest(unittest.TestCase):
    def result(self, detections: list[RawDetection]):
        return build_vision_result(
            frame_id=str(uuid.uuid4()),
            captured_at=datetime(2026, 10, 4, 12, 0, tzinfo=timezone.utc),
            image_size=ImageSize(width=1000, height=1000),
            raw_detections=detections,
            model_name="yolov11n",
            model_version="test",
            thresholds={"bus": 0.50, "bus_door": 0.55},
        )

    def test_serializes_observation_without_risk_or_message_policy(self) -> None:
        previous = self.result([RawDetection("bus", 0.90, 400, 100, 600, 400)])
        current = self.result([RawDetection("bus", 0.90, 350, 100, 650, 500)])

        payload = build_vision_guidance_handoff(current, previous).as_dict()

        self.assertEqual(payload["schemaVersion"], PROPOSED_SCHEMA_VERSION)
        self.assertEqual(payload["frameId"], current.frame_id)
        self.assertEqual(payload["candidates"][0]["direction"], "CENTER")
        self.assertEqual(payload["candidates"][0]["motion"], "APPROACHING")
        self.assertNotIn("riskLevel", payload)
        self.assertNotIn("message", payload)

    def test_serializes_empty_candidates_when_no_bus_is_available(self) -> None:
        current = self.result([])

        payload = build_vision_guidance_handoff(current).as_dict()

        self.assertEqual(payload["candidates"], [])

    def test_adds_door_candidate_when_door_is_inside_bus(self) -> None:
        current = self.result(
            [
                RawDetection("bus", 0.90, 300, 100, 900, 800),
                RawDetection("bus_door", 0.80, 700, 300, 820, 700),
            ]
        )

        payload = build_vision_guidance_handoff(current).as_dict()

        self.assertEqual([candidate["classId"] for candidate in payload["candidates"]], ["bus", "bus_door"])
        door = payload["candidates"][1]
        self.assertEqual(door["direction"], "RIGHT")
        self.assertEqual(door["relativeDistance"], "NEAR")
        self.assertEqual(door["motion"], "UNKNOWN")

    def test_omits_door_candidate_when_door_is_not_inside_bus(self) -> None:
        current = self.result(
            [
                RawDetection("bus", 0.90, 0, 100, 300, 800),
                RawDetection("bus_door", 0.80, 700, 300, 820, 700),
            ]
        )

        payload = build_vision_guidance_handoff(current).as_dict()

        self.assertEqual([candidate["classId"] for candidate in payload["candidates"]], ["bus"])

    def test_context_audio_fixture_is_a_policy_free_bus_and_door_handoff(self) -> None:
        fixture_path = _PIPELINES_DIR / "fixtures" / "bus_door_guidance_candidate.json"
        payload = json.loads(fixture_path.read_text(encoding="utf-8"))

        self.assertEqual(payload["schemaVersion"], PROPOSED_SCHEMA_VERSION)
        self.assertEqual([item["classId"] for item in payload["candidates"]], ["bus", "bus_door"])
        for candidate in payload["candidates"]:
            self.assertIn(candidate["direction"], {"LEFT", "CENTER", "RIGHT"})
            self.assertIn(candidate["relativeDistance"], {"FAR", "MEDIUM", "NEAR"})
            self.assertIn(candidate["motion"], {"UNKNOWN", "APPROACHING", "STABLE", "RECEDING"})
            self.assertGreaterEqual(candidate["confidence"], 0.0)
            self.assertLessEqual(candidate["confidence"], 1.0)
            self.assertGreater(candidate["normalizedArea"], 0.0)
            self.assertNotIn("riskLevel", candidate)
            self.assertNotIn("message", candidate)


if __name__ == "__main__":
    unittest.main()
