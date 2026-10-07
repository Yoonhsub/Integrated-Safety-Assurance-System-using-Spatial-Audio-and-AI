"""TFLite YOLO11 bus 출력 해석의 SDK 비의존 단위 테스트."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from tflite_bus_inference import (  # noqa: E402
    COCO_BUS_CLASS_INDEX,
    decode_bus_detections,
    make_letterbox_transform,
    vision_result_from_tflite_output,
)
from vision_result import ImageSize, VisionResultValidationError  # noqa: E402


def _output_with_candidates(candidates: list[tuple[float, float, float, float, float]]) -> list[list[list[float]]]:
    """(cx, cy, w, h, bus_score) 후보를 YOLO11 [1,84,N] fixture로 만든다."""
    channels = [[0.0 for _ in candidates] for _ in range(84)]
    for index, (cx, cy, width, height, score) in enumerate(candidates):
        channels[0][index] = cx
        channels[1][index] = cy
        channels[2][index] = width
        channels[3][index] = height
        channels[4 + COCO_BUS_CLASS_INDEX][index] = score
    return [channels]


class TfliteBusInferenceTest(unittest.TestCase):
    def test_decodes_bus_and_removes_overlapping_candidate(self) -> None:
        source_size = ImageSize(width=1280, height=720)
        transform = make_letterbox_transform(source_size)
        output = _output_with_candidates(
            [
                # Original xyxy [100,100,500,500] -> letterboxed xywh
                # [150,290,200,200] -> normalized [150/640,290/640,200/640,200/640].
                (150.0 / 640, 290.0 / 640, 200.0 / 640, 200.0 / 640, 0.90),
                (152.0 / 640, 292.0 / 640, 200.0 / 640, 200.0 / 640, 0.80),
            ]
        )

        detections = decode_bus_detections(output, transform=transform)

        self.assertEqual(len(detections), 1)
        detection = detections[0]
        self.assertEqual(detection.class_id, "bus")
        self.assertAlmostEqual(detection.score, 0.90)
        self.assertAlmostEqual(detection.x1, 100.0)
        self.assertAlmostEqual(detection.y1, 100.0)
        self.assertAlmostEqual(detection.x2, 500.0)
        self.assertAlmostEqual(detection.y2, 500.0)

    def test_ignores_low_confidence_bus_candidate(self) -> None:
        output = _output_with_candidates([(0.5, 0.5, 100.0 / 640, 100.0 / 640, 0.49)])
        detections = decode_bus_detections(output, transform=make_letterbox_transform(ImageSize(width=640, height=640)))
        self.assertEqual(detections, [])

    def test_builds_normalized_vision_result(self) -> None:
        output = _output_with_candidates([(0.5, 0.5, 0.5, 0.5, 0.91)])
        result = vision_result_from_tflite_output(output, source_size=ImageSize(width=640, height=640))

        self.assertEqual(len(result.detections), 1)
        self.assertEqual(result.detections[0].class_id, "bus")
        self.assertAlmostEqual(result.detections[0].bbox.x, 0.25)
        self.assertAlmostEqual(result.detections[0].bbox.w, 0.5)

    def test_rejects_unexpected_tensor_layout(self) -> None:
        with self.assertRaises(VisionResultValidationError):
            decode_bus_detections([[[0.0]]], transform=make_letterbox_transform(ImageSize(width=640, height=640)))


if __name__ == "__main__":
    unittest.main()
