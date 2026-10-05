"""Provider interface and explicit provider selection."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Protocol, runtime_checkable

from ai_vision.pipelines.detection_result import DetectionResult
from ai_vision.pipelines.vision_input import VisionInferenceRequest


class ProviderConfigurationError(ValueError):
    """The requested provider is unknown or not implemented."""


@runtime_checkable
class VisionProvider(Protocol):
    """An inference provider that maps a validated request to a DetectionResult."""

    def infer(self, request: VisionInferenceRequest) -> DetectionResult:
        """Run inference for one provider-neutral image/frame request."""


def create_vision_provider(
    provider: str = "mock",
    *,
    scenario: str = "multiple_detections",
    fixture_path: Path | None = None,
    model_path: str | Path | None = None,
    model_factory: Callable[[str], Any] | None = None,
) -> VisionProvider:
    """Create an explicitly selected provider; never silently fall back to mock."""
    if provider == "mock":
        from ai_vision.pipelines.mock_vision_provider import MockVisionProvider

        return MockVisionProvider(scenario=scenario, fixture_path=fixture_path)
    if provider == "yolo":
        if model_path is None:
            raise ProviderConfigurationError(
                "The 'yolo' provider requires an explicit local model_path."
            )
        from ai_vision.pipelines.yolo_vision_provider import YOLOVisionProvider

        return YOLOVisionProvider(model_path, model_factory=model_factory)
    raise ProviderConfigurationError(f"Unknown vision provider: {provider!r}.")
