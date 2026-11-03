"""Tests for the fixture-backed VisionProvider implementation."""
from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from jsonschema import Draft202012Validator, FormatChecker

from ai_vision.pipelines.detection_result import DetectionResult, DetectionStatus
from ai_vision.pipelines.mock_vision_provider import (
    MockFixtureContractError,
    MockFixtureMalformedError,
    MockFixtureMissingError,
    MockScenario,
    MockVisionProvider,
)
from ai_vision.pipelines.vision_provider import (
    ProviderConfigurationError,
    VisionProvider,
    create_vision_provider,
)
from ai_vision.pipelines.vision_input import (
    InvalidVisionInputError,
    MissingImageFileError,
    UnsupportedVisionInputError,
    VisionInferenceRequest,
    VisionInputSource,
)


_TEST_DIR = Path(__file__).resolve().parent
_FIXTURE_PATH = _TEST_DIR.parent / "fixtures" / "mock_detection_results.json"
_SCHEMA_PATH = (
    _TEST_DIR.parents[2]
    / "packages"
    / "shared_contracts"
    / "api"
    / "vision_detection.response.schema.json"
)


class MockVisionProviderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.provider = MockVisionProvider()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.image_path = Path(self.temp_dir.name) / "frame.jpg"
        self.image_path.write_bytes(b"mock image payload")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def request(self, **overrides: object) -> VisionInferenceRequest:
        values: dict[str, object] = {
            "frame_id": str(uuid4()),
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "source": VisionInputSource.IMAGE_FILE,
            "payload": self.image_path,
        }
        values.update(overrides)
        return VisionInferenceRequest(**values)  # type: ignore[arg-type]

    def test_creates_valid_image_file_input(self) -> None:
        request = self.request()
        self.assertEqual(request.source, VisionInputSource.IMAGE_FILE)
        self.assertEqual(request.payload, self.image_path)

    def test_required_metadata_is_passed_to_result(self) -> None:
        request = self.request()
        result = self.provider.infer(request)
        self.assertEqual(result.frame_id, request.frame_id)
        self.assertEqual(result.captured_at, request.captured_at)
        self.assertEqual(result.source, request.source.value)

    def test_returns_multiple_detection_result(self) -> None:
        result = self.provider.infer(self.request())
        self.assertIsInstance(result, DetectionResult)
        self.assertEqual(result.status, DetectionStatus.OK)
        self.assertEqual(len(result.detections), 2)

    def test_returns_normal_empty_detection_result(self) -> None:
        result = MockVisionProvider(scenario=MockScenario.EMPTY).infer(self.request())
        self.assertEqual(result.status, DetectionStatus.OK)
        self.assertEqual(result.detections, ())
        self.assertIsNone(result.error)

    def test_returns_unavailable_status(self) -> None:
        result = MockVisionProvider(scenario=MockScenario.UNAVAILABLE).infer(self.request())
        self.assertEqual(result.status, DetectionStatus.UNAVAILABLE)
        self.assertEqual(result.detections, ())
        self.assertEqual(result.error.code, "SOURCE_UNAVAILABLE")

    def test_returns_error_status(self) -> None:
        result = MockVisionProvider(scenario=MockScenario.ERROR).infer(self.request())
        self.assertEqual(result.status, DetectionStatus.ERROR)
        self.assertEqual(result.detections, ())
        self.assertEqual(result.error.code, "INFERENCE_FAILED")

    def test_missing_fixture_has_distinct_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            missing_fixture = Path(temp_dir) / "missing.json"
            provider = MockVisionProvider(fixture_path=missing_fixture)
            with self.assertRaises(MockFixtureMissingError):
                provider.infer(self.request())

    def test_missing_image_file_has_distinct_error(self) -> None:
        with self.assertRaises(MissingImageFileError):
            self.request(payload=Path(self.temp_dir.name) / "missing.jpg")

    def test_malformed_fixture_has_distinct_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_path = Path(temp_dir) / "malformed.json"
            fixture_path.write_text("{bad json", encoding="utf-8")
            provider = MockVisionProvider(fixture_path=fixture_path)
            with self.assertRaises(MockFixtureMalformedError):
                provider.infer(self.request())

    def test_contract_invalid_fixture_has_distinct_error(self) -> None:
        fixture = json.loads(_FIXTURE_PATH.read_text(encoding="utf-8"))
        fixture["results"][0]["detections"][0]["confidence"] = 1.5
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_path = Path(temp_dir) / "invalid.json"
            fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
            provider = MockVisionProvider(fixture_path=fixture_path)
            with self.assertRaises(MockFixtureContractError):
                provider.infer(self.request())

    def test_rejects_unsupported_request_type(self) -> None:
        with self.assertRaises(UnsupportedVisionInputError):
            self.provider.infer(object())  # type: ignore[arg-type]

    def test_rejects_unsupported_input_source(self) -> None:
        with self.assertRaises(UnsupportedVisionInputError):
            self.request(source="webcam")

    def test_rejects_invalid_payload_type(self) -> None:
        with self.assertRaises(UnsupportedVisionInputError):
            self.request(payload=b"image bytes")

    def test_rejects_missing_required_metadata(self) -> None:
        with self.assertRaises(InvalidVisionInputError):
            self.request(frame_id=None)

    def test_factory_selects_mock_and_rejects_unknown_or_unimplemented_provider(self) -> None:
        self.assertIsInstance(create_vision_provider("mock"), MockVisionProvider)
        self.assertIsInstance(create_vision_provider("mock"), VisionProvider)
        for provider_name in ("unknown", "yolo"):
            with self.subTest(provider=provider_name):
                with self.assertRaises(ProviderConfigurationError):
                    create_vision_provider(provider_name)

    def test_detection_result_json_serialization_round_trip(self) -> None:
        result = self.provider.infer(self.request())
        serialized = json.dumps(result.to_dict(), ensure_ascii=False)
        deserialized = DetectionResult.from_dict(json.loads(serialized))
        self.assertEqual(deserialized, result)

    def test_provider_results_validate_against_shared_schema(self) -> None:
        schema = json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        for scenario in MockScenario:
            with self.subTest(scenario=scenario.value):
                result = MockVisionProvider(scenario=scenario).infer(self.request())
                validator.validate(result.to_dict())


if __name__ == "__main__":
    unittest.main(verbosity=2)
