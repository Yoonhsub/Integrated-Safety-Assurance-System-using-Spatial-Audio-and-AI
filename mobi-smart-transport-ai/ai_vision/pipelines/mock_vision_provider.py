"""Fixture-backed mock implementation of VisionProvider."""
from __future__ import annotations

import json
from dataclasses import replace
from enum import Enum
from pathlib import Path
from typing import Any

from ai_vision.pipelines.detection_result import DetectionResult
from ai_vision.pipelines.vision_input import (
    UnsupportedVisionInputError,
    VisionInferenceRequest,
)


DEFAULT_FIXTURE_PATH = (
    Path(__file__).resolve().parent / "fixtures" / "mock_detection_results.json"
)
DEFAULT_SCHEMA_PATH = (
    Path(__file__).resolve().parents[2]
    / "packages"
    / "shared_contracts"
    / "api"
    / "vision_detection.response.schema.json"
)


class MockScenario(str, Enum):
    MULTIPLE_DETECTIONS = "multiple_detections"
    EMPTY = "empty"
    UNAVAILABLE = "unavailable"
    ERROR = "error"


class MockFixtureError(RuntimeError):
    """Base error for loading or validating the mock inference fixture."""


class MockFixtureMissingError(MockFixtureError):
    """The configured mock fixture file does not exist."""


class MockFixtureMalformedError(MockFixtureError):
    """The configured mock fixture is not valid JSON or has an invalid envelope."""


class MockFixtureContractError(MockFixtureError):
    """A result in the mock fixture violates the shared DetectionResult schema."""


class MockVisionProvider:
    """Return a selected scenario from the checked-in DetectionResult fixture."""

    def __init__(
        self,
        *,
        scenario: str | MockScenario = MockScenario.MULTIPLE_DETECTIONS,
        fixture_path: Path | None = None,
        schema_path: Path | None = None,
    ) -> None:
        try:
            self.scenario = MockScenario(scenario)
        except ValueError as exc:
            supported = ", ".join(item.value for item in MockScenario)
            raise ValueError(
                f"Unknown mock scenario {scenario!r}; expected one of: {supported}."
            ) from exc
        self.fixture_path = fixture_path or DEFAULT_FIXTURE_PATH
        self.schema_path = schema_path or DEFAULT_SCHEMA_PATH

    def infer(self, request: VisionInferenceRequest) -> DetectionResult:
        """Return the selected fixture result with metadata from the request."""
        if not isinstance(request, VisionInferenceRequest):
            raise UnsupportedVisionInputError(
                "MockVisionProvider requires a VisionInferenceRequest."
            )
        results = self._load_results()
        selected = self._select_result(results)
        result = DetectionResult.from_dict(selected)
        return replace(
            result,
            source=request.source.value,
            frame_id=request.frame_id,
            captured_at=request.captured_at,
        )

    def _load_results(self) -> list[dict[str, Any]]:
        if not self.fixture_path.is_file():
            raise MockFixtureMissingError(
                f"Mock fixture not found: {self.fixture_path}"
            )
        try:
            with self.fixture_path.open(encoding="utf-8") as fixture_file:
                payload = json.load(fixture_file)
        except json.JSONDecodeError as exc:
            raise MockFixtureMalformedError(
                f"Mock fixture contains malformed JSON: {self.fixture_path}: {exc}"
            ) from exc
        except OSError as exc:
            raise MockFixtureMalformedError(
                f"Mock fixture could not be read: {self.fixture_path}: {exc}"
            ) from exc

        if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
            raise MockFixtureMalformedError(
                "Mock fixture must be an object containing a 'results' array."
            )

        try:
            from jsonschema import Draft202012Validator, FormatChecker
            from jsonschema.exceptions import ValidationError
        except ImportError as exc:  # pragma: no cover - runtime setup supplies jsonschema
            raise MockFixtureContractError(
                "jsonschema is required to validate mock DetectionResult fixtures; "
                "install ai_vision/requirements.txt."
            ) from exc

        try:
            schema = json.loads(self.schema_path.read_text(encoding="utf-8"))
            validator = Draft202012Validator(
                schema,
                format_checker=FormatChecker(),
            )
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            raise MockFixtureContractError(
                f"DetectionResult schema could not be loaded: {self.schema_path}: {exc}"
            ) from exc

        for index, result in enumerate(payload["results"]):
            try:
                validator.validate(result)
            except ValidationError as exc:
                raise MockFixtureContractError(
                    f"Mock result at index {index} violates the DetectionResult schema: "
                    f"{exc.message}"
                ) from exc
        return payload["results"]

    def _select_result(self, results: list[dict[str, Any]]) -> dict[str, Any]:
        for result in results:
            detections = result.get("detections", [])
            status = result.get("status")
            if self.scenario is MockScenario.MULTIPLE_DETECTIONS:
                matches = status == "ok" and len(detections) > 1
            elif self.scenario is MockScenario.EMPTY:
                matches = status == "ok" and not detections
            else:
                matches = status == self.scenario.value
            if matches:
                return result
        raise MockFixtureContractError(
            f"Mock fixture does not contain scenario {self.scenario.value!r}."
        )
