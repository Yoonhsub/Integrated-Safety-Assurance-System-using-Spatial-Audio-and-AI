"""OpenCV frame sources for local video files and webcams."""
from __future__ import annotations

import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import uuid4

from ai_vision.pipelines.vision_input import (
    FrameImagePayload,
    InvalidVisionInputError,
    VisionInferenceRequest,
    VisionInputSource,
)


class FrameSourceError(RuntimeError):
    """Base error for opening or reading a continuous frame source."""


class FrameSourceConfigurationError(FrameSourceError):
    """OpenCV or source configuration is unavailable."""


class FrameSourceOpenError(FrameSourceError):
    """The video or camera source could not be opened."""


class FrameSourceReadError(FrameSourceError):
    """A live frame source failed while reading a frame."""


class MalformedFrameError(FrameSourceError):
    """A source returned a frame that is not a valid color image array."""


@runtime_checkable
class FrameSource(Protocol):
    """Acquire requests and own only frame metadata and capture lifecycle."""

    @property
    def fps(self) -> float | None: ...

    @property
    def frame_index(self) -> int: ...

    def open(self) -> None: ...

    def read(self) -> VisionInferenceRequest | None:
        """Return the next frame request, or None at normal end-of-file."""

    def close(self) -> None: ...


class _OpenCVFrameSource:
    source: VisionInputSource

    def __init__(self, *, cv2_module: Any | None = None) -> None:
        self._cv2 = cv2_module
        self._capture: Any | None = None
        self._fps: float | None = None
        self._frame_index = -1

    @property
    def fps(self) -> float | None:
        return self._fps

    @property
    def frame_index(self) -> int:
        return self._frame_index

    def open(self) -> None:
        if self._capture is not None:
            return
        cv2 = self._opencv()
        capture = None
        try:
            capture = self._create_capture(cv2)
            opened = capture is not None and capture.isOpened()
        except Exception as exc:
            if capture is not None:
                capture.release()
            raise FrameSourceOpenError(
                f"Could not initialize {self.source.value} frame source: {exc}"
            ) from exc
        if not opened:
            if capture is not None:
                capture.release()
            raise FrameSourceOpenError(f"Could not open {self.source.value} frame source.")
        self._capture = capture
        try:
            reported_fps = float(capture.get(cv2.CAP_PROP_FPS))
        except (AttributeError, TypeError, ValueError):
            reported_fps = 0.0
        self._fps = reported_fps if math.isfinite(reported_fps) and reported_fps > 0 else None

    def read(self) -> VisionInferenceRequest | None:
        if self._capture is None:
            raise FrameSourceOpenError("Frame source must be opened before reading.")
        try:
            ok, image = self._capture.read()
        except Exception as exc:
            raise FrameSourceReadError(
                f"{self.source.value} frame read failed: {exc}"
            ) from exc
        if not ok:
            if self.source is VisionInputSource.VIDEO_FILE:
                return None
            raise FrameSourceReadError("Webcam failed to read a frame.")
        try:
            payload = FrameImagePayload(image)
        except InvalidVisionInputError as exc:
            raise MalformedFrameError(f"Invalid frame from {self.source.value}: {exc}") from exc

        self._frame_index += 1
        return VisionInferenceRequest(
            frame_id=str(uuid4()),
            captured_at=datetime.now(timezone.utc).isoformat(),
            source=self.source,
            payload=payload,
            frame_index=self._frame_index,
        )

    def close(self) -> None:
        capture, self._capture = self._capture, None
        if capture is not None:
            capture.release()

    def _opencv(self) -> Any:
        if self._cv2 is None:
            try:
                import cv2
            except ImportError as exc:
                raise FrameSourceConfigurationError(
                    "Video/webcam input requires OpenCV, provided by the AI Vision "
                    "Ultralytics runtime requirements."
                ) from exc
            self._cv2 = cv2
        return self._cv2

    def _create_capture(self, cv2: Any) -> Any:
        raise NotImplementedError


class VideoFileSource(_OpenCVFrameSource):
    """Read a local video sequentially; OpenCV's false read at EOF is normal."""

    source = VisionInputSource.VIDEO_FILE

    def __init__(self, path: str | Path, *, cv2_module: Any | None = None) -> None:
        super().__init__(cv2_module=cv2_module)
        if not isinstance(path, (str, Path)) or not str(path).strip():
            raise FrameSourceConfigurationError("A video file path is required.")
        self.path = Path(path).expanduser().resolve()
        if not self.path.is_file():
            raise FrameSourceOpenError(f"Video file not found: {self.path}")

    def _create_capture(self, cv2: Any) -> Any:
        return cv2.VideoCapture(str(self.path))


class WebcamSource(_OpenCVFrameSource):
    """Read local webcam frames using OpenCV's platform-default camera backend."""

    source = VisionInputSource.WEBCAM

    def __init__(self, camera_index: int = 0, *, cv2_module: Any | None = None) -> None:
        super().__init__(cv2_module=cv2_module)
        if isinstance(camera_index, bool) or not isinstance(camera_index, int) or camera_index < 0:
            raise FrameSourceConfigurationError("camera_index must be a non-negative integer.")
        self.camera_index = camera_index

    def _create_capture(self, cv2: Any) -> Any:
        return cv2.VideoCapture(self.camera_index)
