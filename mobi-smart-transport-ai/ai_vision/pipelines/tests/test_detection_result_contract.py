"""Shared DetectionResult schema and fixture contract tests."""
from __future__ import annotations

import json
import unittest
from copy import deepcopy
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import ValidationError


_THIS_DIR = Path(__file__).resolve().parent
_PROJECT_ROOT = _THIS_DIR.parents[2]
_SCHEMA_PATH = (
    _PROJECT_ROOT
    / "packages"
    / "shared_contracts"
    / "api"
    / "vision_detection.response.schema.json"
)
_FIXTURE_PATH = _THIS_DIR.parent / "fixtures" / "mock_detection_results.json"
_LEGACY_FIXTURE_PATH = (
    _THIS_DIR.parent / "fixtures" / "mock_safety_events.json"
)


class DetectionResultContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.fixture = json.loads(_FIXTURE_PATH.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(cls.schema)
        cls.validator = Draft202012Validator(
            cls.schema,
            format_checker=FormatChecker(),
        )

    def assert_valid(self, result: dict[str, Any]) -> None:
        self.validator.validate(result)

    def assert_invalid(self, result: dict[str, Any]) -> None:
        with self.assertRaises(ValidationError):
            self.validator.validate(result)

    def test_fixture_results_validate_and_cover_required_cases(self) -> None:
        results = self.fixture["results"]
        self.assertEqual(len(results), 4)
        for result in results:
            with self.subTest(status=result["status"], detections=result["detections"]):
                self.assert_valid(result)

        self.assertGreaterEqual(len(results[0]["detections"]), 2)
        self.assertEqual(results[1]["status"], "ok")
        self.assertEqual(results[1]["detections"], [])
        self.assertEqual(results[2]["status"], "unavailable")
        self.assertEqual(results[3]["status"], "error")

    def test_confidence_outside_unit_interval_is_rejected(self) -> None:
        result = deepcopy(self.fixture["results"][0])
        result["detections"][0]["confidence"] = 1.01
        self.assert_invalid(result)

    def test_bbox_outside_normalized_range_is_rejected(self) -> None:
        result = deepcopy(self.fixture["results"][0])
        result["detections"][0]["bbox"]["x"] = -0.01
        self.assert_invalid(result)

    def test_class_id_and_class_name_must_match_taxonomy(self) -> None:
        class_names = {
            "bus": "버스",
            "bus_door": "버스 문",
            "bus_stop": "버스 정류장",
            "roadway": "차도",
            "sidewalk": "보도",
            "obstacle": "장애물",
            "tactile_paving": "점자블록",
        }
        detection_template = deepcopy(self.fixture["results"][0]["detections"][0])
        result_template = deepcopy(self.fixture["results"][0])

        for class_id, class_name in class_names.items():
            with self.subTest(class_id=class_id, class_name=class_name):
                result = deepcopy(result_template)
                result["detections"] = [
                    {**detection_template, "classId": class_id, "className": class_name}
                ]
                self.assert_valid(result)

                for wrong_class_name in set(class_names.values()) - {class_name}:
                    mismatched = deepcopy(result)
                    mismatched["detections"][0]["className"] = wrong_class_name
                    with self.subTest(wrong_class_name=wrong_class_name):
                        self.assert_invalid(mismatched)

    def test_unknown_status_is_rejected(self) -> None:
        result = deepcopy(self.fixture["results"][0])
        result["status"] = "failed"
        self.assert_invalid(result)

    def test_required_fields_are_enforced(self) -> None:
        result = deepcopy(self.fixture["results"][0])
        del result["schemaVersion"]
        self.assert_invalid(result)

        for field in ("frameId", "capturedAt", "modelInfo"):
            with self.subTest(missing_field=field):
                result = deepcopy(self.fixture["results"][0])
                del result[field]
                self.assert_invalid(result)

    def test_ok_status_rejects_error_field(self) -> None:
        result = deepcopy(self.fixture["results"][0])
        result["error"] = {"code": "INFERENCE_FAILED", "message": "failed"}
        self.assert_invalid(result)

    def test_unavailable_and_error_cannot_be_mistaken_for_no_detection(self) -> None:
        unavailable = deepcopy(self.fixture["results"][2])
        error = deepcopy(self.fixture["results"][3])
        self.assert_valid(unavailable)
        self.assert_valid(error)

        unavailable["detections"] = [deepcopy(self.fixture["results"][0]["detections"][0])]
        self.assert_invalid(unavailable)

        for result in (self.fixture["results"][2], self.fixture["results"][3]):
            with self.subTest(status=result["status"]):
                missing_error = deepcopy(result)
                del missing_error["error"]
                self.assert_invalid(missing_error)

    def test_additional_properties_are_rejected(self) -> None:
        result = deepcopy(self.fixture["results"][0])
        result["riskLevel"] = "danger"
        self.assert_invalid(result)

    def test_existing_mock_safety_event_fixture_is_unchanged_and_readable(self) -> None:
        legacy_fixture = json.loads(_LEGACY_FIXTURE_PATH.read_text(encoding="utf-8"))
        self.assertEqual(len(legacy_fixture["events"]), 4)
        self.assertIn("riskLevel", legacy_fixture["events"][0])
        self.assertIn("reason", legacy_fixture["events"][0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
