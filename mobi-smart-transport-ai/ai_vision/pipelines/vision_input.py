"""Validated input metadata and payload for one image or captured frame."""
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
    VIDEO_FILE = "video_file"
    WEBCAM = "webcam"


@dataclass(frozen=True)
class FrameImagePayload:
    """Provider-neutral wrapper around an in-memory HxWxC image array.

    It avoids importing OpenCV, NumPy, or PIL into the request contract. OpenCV
    frames are passed directly to Ultralytics without writing temporary files.
    """

    image: object

    def __post_init__(self) -> None:
        shape = getattr(self.image, "shape", None)
        ndim = getattr(self.image, "ndim", None)
        if not isinstance(shape, (tuple, list)) or len(shape) != 3 or ndim != 3:
            raise InvalidVisionInputError(
                "In-memory frame must be a three-dimensional image array."
            )
        try:
            height, width, channels = (int(value) for value in shape)
        except (TypeError, ValueError, OverflowError) as exc:
            raise InvalidVisionInputError("In-memory frame has an invalid shape.") from exc
        if height <= 0 or width <= 0 or channels != 3:
            raise InvalidVisionInputError(
                "In-memory frame must have positive height/width and 3 color channels."
            )


@dataclass(frozen=True)
class VisionInferenceRequest:
    """One input's identity, capture time, source, and provider-neutral payload."""

    frame_id: str
    captured_at: str
    source: VisionInputSource
    payload: Path | FrameImagePayload
    frame_index: int | None = None

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
        if captured_at.tzinfo is None or captured_at.utcoffset() is None:
            raise InvalidVisionInputError("captured_at must include a timezone.")

        if self.frame_index is not None and (
            isinstance(self.frame_index, bool)
            or not isinstance(self.frame_index, int)
            or self.frame_index < 0
        ):
            raise InvalidVisionInputError("frame_index must be a non-negative integer.")

        if not isinstance(self.source, VisionInputSource):
            raise UnsupportedVisionInputError(
                f"Unsupported vision input source: {self.source!r}."
            )
        if self.source is VisionInputSource.IMAGE_FILE:
            if not isinstance(self.payload, Path):
                raise UnsupportedVisionInputError(
                    "image_file payload must be a pathlib.Path."
                )
            if not self.payload.is_file():
                raise MissingImageFileError(f"Image file not found: {self.payload}")
            if self.frame_index is not None:
                raise InvalidVisionInputError("image_file requests cannot have frame_index.")
            return

        if self.source in {VisionInputSource.VIDEO_FILE, VisionInputSource.WEBCAM}:
            if not isinstance(self.payload, FrameImagePayload):
                raise UnsupportedVisionInputError(
                    f"{self.source.value} payload must be an in-memory FrameImagePayload."
                )
            if self.frame_index is None:
                raise InvalidVisionInputError(
                    f"{self.source.value} requests require frame_index."
                )
            return

        raise UnsupportedVisionInputError(
            f"Vision input source {self.source.value!r} is not supported yet."
        )
