"""Validated input metadata and payload for a single vision inference request."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from pathlib import Path
from uuid import UUID


class VisionInputError(ValueError):
    """Base error for invalid or unsupported vision inputs."""


class UnsupportedVisionInputError(VisionInputError):
    """The input source or payload type is not supported."""


class InvalidVisionInputError(VisionInputError):
    """Required input metadata or payload is invalid."""


class MissingImageFileError(VisionInputError):
    """The requested local image file does not exist or is not a file."""


class VisionInputSource(str, Enum):
    IMAGE_FILE = "image_file"


@dataclass(frozen=True)
class VisionInferenceRequest:
    """One frame's identity, capture time, source, and provider-neutral payload."""

    frame_id: str
    captured_at: str
    source: VisionInputSource
    payload: Path

    def __post_init__(self) -> None:
        if not isinstance(self.frame_id, str) or not self.frame_id.strip():
            raise InvalidVisionInputError("frame_id is required.")
        try:
            UUID(self.frame_id)
        except ValueError as exc:
            raise InvalidVisionInputError("frame_id must be a UUID.") from exc

        if not isinstance(self.captured_at, str) or not self.captured_at.strip():
            raise InvalidVisionInputError("captured_at is required.")
        try:
            captured_at = datetime.fromisoformat(self.captured_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise InvalidVisionInputError(
                "captured_at must be an ISO 8601 date-time."
            ) from exc
        if captured_at.tzinfo is None:
            raise InvalidVisionInputError("captured_at must include a timezone.")

        if not isinstance(self.source, VisionInputSource):
            raise UnsupportedVisionInputError(
                f"Unsupported vision input source: {self.source!r}."
            )
        if self.source is not VisionInputSource.IMAGE_FILE:
            raise UnsupportedVisionInputError(
                f"Vision input source {self.source.value!r} is not supported yet."
            )

        if not isinstance(self.payload, Path):
            raise UnsupportedVisionInputError(
                "image_file payload must be a pathlib.Path."
            )
        if not self.payload.is_file():
            raise MissingImageFileError(f"Image file not found: {self.payload}")
