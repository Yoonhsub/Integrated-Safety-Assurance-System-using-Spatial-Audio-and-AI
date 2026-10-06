"""실제 모델 어댑터 직전의 VisionResult 계약 검증."""

from __future__ import annotations

import sys
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from vision_result import (  # noqa: E402
    ImageSize,
    RawDetection,
    VisionResultValidationError,
    build_vision_result,
)


class VisionResultTest(unittest.TestCase):
    def setUp(self) -> None:
        self.image_size = ImageSize(width=1920, height=1080)
        self.timestamp = datetime(2026, 9, 24, 9, 0, tzinfo=timezone.utc)
        self.frame_id = str(uuid.uuid4())
        self.thresholds = {"bus": 0.50, "bus_door": 0.55}

    def build(self, raw_detections: list[RawDetection]):
        return build_vision_result(
            frame_id=self.frame_id,
            captured_at=self.timestamp,
            image_size=self.image_size,
            raw_detections=raw_detections,
            model_name="yolov11n",
            model_version="0.1.0",
            thresholds=self.thresholds,
        )

    def test_normalizes_pixel_xyxy_and_serializes_candidate_contract(self) -> None:
        result = self.build(
            [RawDetection("bus", 0.88, 192, 108, 1152, 648)]
        )

        self.assertEqual(len(result.detections), 1)
        self.assertEqual(
            result.as_contract_payload()["detections"],
            [{"classId": "bus", "bbox": {"x": 0.1, "y": 0.1, "w": 0.5, "h": 0.5}, "score": 0.88}],
        )
        self.assertEqual(result.as_contract_payload()["frameId"], self.frame_id)

    def test_filters_unknown_and_below_threshold_classes(self) -> None:
        result = self.build(
            [
                RawDetection("car", 0.99, 1, 1, 10, 10),
                RawDetection("bus", 0.49, 1, 1, 10, 10),
                RawDetection("bus_door", 0.55, 1, 1, 10, 10),
            ]
        )
        self.assertEqual([d.class_id for d in result.detections], ["bus_door"])

    def test_clips_partly_outside_box_to_image_boundary(self) -> None:
        result = self.build([RawDetection("bus", 0.90, -10, 100, 2000, 1200)])
        bbox = result.detections[0].bbox
        self.assertEqual((bbox.x, bbox.y, bbox.w, bbox.h), (0.0, 100 / 1080, 1.0, 1.0 - 100 / 1080))

    def test_rejects_degenerate_or_invalid_score_for_known_class(self) -> None:
        with self.assertRaises(VisionResultValidationError):
            self.build([RawDetection("bus", 0.90, 10, 10, 10, 40)])
        with self.assertRaises(VisionResultValidationError):
            self.build([RawDetection("bus", 1.01, 10, 10, 40, 40)])

    def test_requires_uuid_v4_and_timezone(self) -> None:
        with self.assertRaises(VisionResultValidationError):
            build_vision_result(
                frame_id="not-a-uuid",
                captured_at=self.timestamp,
                image_size=self.image_size,
                raw_detections=[],
                model_name="yolov11n",
                model_version="0.1.0",
                thresholds=self.thresholds,
            )
        with self.assertRaises(VisionResultValidationError):
            build_vision_result(
                frame_id=str(uuid.uuid4()),
                captured_at=datetime(2026, 9, 24, 9, 0),
                image_size=self.image_size,
                raw_detections=[],
                model_name="yolov11n",
                model_version="0.1.0",
                thresholds=self.thresholds,
            )
