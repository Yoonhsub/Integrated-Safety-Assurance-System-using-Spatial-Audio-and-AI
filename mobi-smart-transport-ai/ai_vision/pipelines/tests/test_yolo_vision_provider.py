"""Offline unit tests for the Ultralytics provider adapter."""
from __future__ import annotations

import builtins
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from jsonschema import Draft202012Validator, FormatChecker

from ai_vision.pipelines.detection_result import DetectionResult, DetectionStatus
from ai_vision.pipelines.vision_input import VisionInferenceRequest, VisionInputSource
from ai_vision.pipelines.vision_provider import (
    ProviderConfigurationError,
    create_vision_provider,
)
from ai_vision.pipelines.yolo_vision_provider import YOLOVisionProvider


_SCHEMA_PATH = (
    Path(__file__).resolve().parents[3]
    / "packages"
    / "shared_contracts"
    / "api"
    / "vision_detection.response.schema.json"
)


class StubBoxes:
    def __init__(
        self,
        xyxy: list[list[float]],
        classes: list[float],
        confidences: list[float],
    ) -> None:
        self.xyxy = xyxy
        self.cls = classes
        self.conf = confidences


class StubResult:
    names = {0: "person", 5: "bus", 11: "stop sign"}
    orig_shape = (100, 200)

    def __init__(self, boxes: StubBoxes | None) -> None:
        self.boxes = boxes


class StubModel:
    def __init__(self, predictions: list[StubResult] | Exception) -> None:
        self.predictions = predictions
        self.calls: list[dict[str, object]] = []

    def predict(self, **kwargs: object) -> list[StubResult]:
        self.calls.append(kwargs)
        if isinstance(self.predictions, Exception):
            raise self.predictions
        return self.predictions


class YOLOVisionProviderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.model_path = self.root / "yolo11n.pt"
        self.model_path.write_bytes(b"stub weights")
        self.image_path = self.root / "frame.jpg"
        self.image_path.write_bytes(b"stub image")
        self.request = VisionInferenceRequest(
            frame_id=str(uuid4()),
            captured_at="2026-10-05T12:30:00+09:00",
            source=VisionInputSource.IMAGE_FILE,
            payload=self.image_path,
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def provider(self, model: StubModel) -> YOLOVisionProvider:
        return YOLOVisionProvider(self.model_path, model_factory=lambda _: model)

    def test_provider_can_be_created_with_injected_model_factory(self) -> None:
        calls: list[str] = []

        def factory(path: str) -> StubModel:
            calls.append(path)
            return StubModel([])

        provider = YOLOVisionProvider(self.model_path, model_factory=factory)
        self.assertEqual(calls, [str(self.model_path.resolve())])
        self.assertEqual(provider.model_info.provider, "ultralytics")
        self.assertEqual(provider.model_info.name, "yolo11n")

    def test_converts_normal_detection_and_preserves_request_metadata(self) -> None:
        model = StubModel(
            [StubResult(StubBoxes([[20, 10, 180, 90]], [5], [0.87]))]
        )
        result = self.provider(model).infer(self.request)

        self.assertEqual(result.status, DetectionStatus.OK)
        self.assertEqual(result.source, "image_file")
        self.assertEqual(result.frame_id, self.request.frame_id)
        self.assertEqual(result.captured_at, self.request.captured_at)
        self.assertEqual(result.model_info.provider, "ultralytics")
        self.assertEqual(result.model_info.name, "yolo11n")
        self.assertEqual(result.model_info.identifier, str(self.model_path.resolve()))
        self.assertEqual(model.calls[0]["source"], str(self.image_path))

    def test_empty_detection_is_successful_empty_result(self) -> None:
        result = self.provider(StubModel([StubResult(StubBoxes([], [], []))])).infer(
            self.request
        )
        self.assertEqual(result.status, DetectionStatus.OK)
        self.assertEqual(result.detections, ())
        self.assertIsNone(result.error)

    def test_bbox_is_normalized_from_pixel_coordinates(self) -> None:
        result = self.provider(
            StubModel([StubResult(StubBoxes([[20, 10, 180, 90]], [5], [0.87]))])
        ).infer(self.request)
        bbox = result.detections[0].bbox
        self.assertEqual((bbox.x, bbox.y, bbox.w, bbox.h), (0.1, 0.1, 0.8, 0.8))

    def test_confidence_is_preserved(self) -> None:
        result = self.provider(
            StubModel([StubResult(StubBoxes([[20, 10, 180, 90]], [5], [0.87]))])
        ).infer(self.request)
        self.assertAlmostEqual(result.detections[0].confidence, 0.87)

    def test_coco_bus_maps_to_project_taxonomy(self) -> None:
        result = self.provider(
            StubModel([StubResult(StubBoxes([[20, 10, 180, 90]], [5], [0.87]))])
        ).infer(self.request)
        self.assertEqual(result.detections[0].class_id, "bus")
        self.assertEqual(result.detections[0].class_name, "버스")

    def test_unmapped_coco_classes_are_ignored(self) -> None:
        result = self.provider(
            StubModel(
                [
                    StubResult(
                        StubBoxes(
                            [[0, 0, 10, 10], [20, 10, 180, 90]],
                            [0, 11],
                            [0.99, 0.95],
                        )
                    )
                ]
            )
        ).infer(self.request)
        self.assertEqual(result.status, DetectionStatus.OK)
        self.assertEqual(result.detections, ())

    def test_inference_exception_becomes_error_not_empty_success(self) -> None:
        result = self.provider(StubModel(RuntimeError("inference failed"))).infer(
            self.request
        )
        self.assertEqual(result.status, DetectionStatus.ERROR)
        self.assertEqual(result.detections, ())
        self.assertEqual(result.error.code, "INFERENCE_FAILED")

    def test_missing_model_is_configuration_error_without_download(self) -> None:
        with self.assertRaisesRegex(ProviderConfigurationError, "existing local"):
            YOLOVisionProvider(self.root / "missing.pt")

    def test_missing_ultralytics_dependency_is_configuration_error(self) -> None:
        real_import = builtins.__import__

        def import_without_ultralytics(name: str, *args: object, **kwargs: object):
            if name == "ultralytics":
                raise ModuleNotFoundError("No module named 'ultralytics'")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=import_without_ultralytics):
            with self.assertRaisesRegex(ProviderConfigurationError, "requires Ultralytics"):
                YOLOVisionProvider(self.model_path)

    def test_factory_selects_yolo_and_requires_model_path(self) -> None:
        model = StubModel([])
        provider = create_vision_provider(
            "yolo",
            model_path=self.model_path,
            model_factory=lambda _: model,
        )
        self.assertIsInstance(provider, YOLOVisionProvider)
        with self.assertRaisesRegex(ProviderConfigurationError, "requires an explicit"):
            create_vision_provider("yolo")

    def test_factory_rejects_unknown_provider(self) -> None:
        with self.assertRaises(ProviderConfigurationError):
            create_vision_provider("unknown")

    def test_success_and_error_results_match_shared_schema(self) -> None:
        schema = json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        results = (
            self.provider(
                StubModel([StubResult(StubBoxes([[20, 10, 180, 90]], [5], [0.87]))])
            ).infer(self.request),
            self.provider(StubModel(RuntimeError("failed"))).infer(self.request),
        )
        for result in results:
            with self.subTest(status=result.status.value):
                self.assertIsInstance(result, DetectionResult)
                validator.validate(result.to_dict())


if __name__ == "__main__":
    unittest.main(verbosity=2)
