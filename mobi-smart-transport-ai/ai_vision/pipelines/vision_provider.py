"""Provider interface and explicit provider selection."""
from __future__ import annotations

from pathlib import Path
from typing import Protocol, runtime_checkable

from ai_vision.pipelines.detection_result import DetectionResult


class ProviderConfigurationError(ValueError):
    """The requested provider is unknown or not implemented."""


@runtime_checkable
class VisionProvider(Protocol):
    """An inference provider that maps an opaque input to a DetectionResult."""

    def infer(self, request: object) -> DetectionResult:
        """Run inference for an input payload without prescribing its media type."""


def create_vision_provider(
    provider: str = "mock",
    *,
    scenario: str = "multiple_detections",
    fixture_path: Path | None = None,
) -> VisionProvider:
    """Create an explicitly selected provider; never silently fall back to mock."""
    if provider == "mock":
        from ai_vision.pipelines.mock_vision_provider import MockVisionProvider

        return MockVisionProvider(scenario=scenario, fixture_path=fixture_path)
    if provider == "yolo":
        raise ProviderConfigurationError(
            "The 'yolo' provider is not implemented yet."
        )
    raise ProviderConfigurationError(f"Unknown vision provider: {provider!r}.")
