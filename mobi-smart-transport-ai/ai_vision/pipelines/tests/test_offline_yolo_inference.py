"""오프라인 YOLO 결과 변환의 SDK 비의존 단위 테스트."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from offline_yolo_inference import (  # noqa: E402
    frame_indices_to_process,
    raw_detections_from_model_outputs,
)
from vision_result import VisionResultValidationError  # noqa: E402


class OfflineYoloInferenceTest(unittest.TestCase):
    def test_converts_yolo_arrays_to_raw_detections(self) -> None:
        detections = raw_detections_from_model_outputs(
            class_indices=[5.0, 0.0],
            scores=[0.88, 0.70],
            boxes_xyxy=[[10.0, 20.0, 110.0, 220.0], [1.0, 2.0, 3.0, 4.0]],
            names={0: "person", 5: "bus"},
        )
        self.assertEqual(detections[0].class_id, "bus")
        self.assertEqual(detections[0].score, 0.88)
        self.assertEqual((detections[0].x1, detections[0].y2), (10.0, 220.0))

    def test_rejects_mismatched_yolo_arrays(self) -> None:
        with self.assertRaises(VisionResultValidationError):
            raw_detections_from_model_outputs(
                class_indices=[5.0],
                scores=[],
                boxes_xyxy=[],
                names={5: "bus"},
            )

    def test_rejects_unknown_class_index(self) -> None:
        with self.assertRaises(VisionResultValidationError):
            raw_detections_from_model_outputs(
                class_indices=[7.0],
                scores=[0.9],
                boxes_xyxy=[[1.0, 2.0, 3.0, 4.0]],
                names={5: "bus"},
            )

    def test_selects_evenly_spaced_video_frames_with_a_cap(self) -> None:
        self.assertEqual(
            frame_indices_to_process(total_frames=100, frame_stride=15, max_samples=4),
            [0, 15, 30, 45],
        )

    def test_rejects_invalid_video_sampling_arguments(self) -> None:
        with self.assertRaises(VisionResultValidationError):
            frame_indices_to_process(total_frames=10, frame_stride=0, max_samples=1)
        with self.assertRaises(VisionResultValidationError):
            frame_indices_to_process(total_frames=10, frame_stride=1, max_samples=0)
