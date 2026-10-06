"""Offline tests for frame inputs, local sources, and stream orchestration."""
from __future__ import annotations

from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from uuid import uuid4

import pytest

from ai_vision.pipelines.backend_safety_event_client import BackendSafetyEventOutcome
from ai_vision.pipelines.detection_result import (
    BoundingBox,
    Detection,
    DetectionError,
    DetectionResult,
    DetectionStatus,
    ModelInfo,
)
from ai_vision.pipelines.frame_sources import (
    FrameSourceOpenError,
    FrameSourceReadError,
    MalformedFrameError,
    VideoFileSource,
    WebcamSource,
)
from ai_vision.pipelines.safety_interpreter import (
    InterpretationStatus,
    SafetyInterpreter,
)
from ai_vision.pipelines.vision_input import (
    FrameImagePayload,
    InvalidVisionInputError,
    VisionInferenceRequest,
    VisionInputSource,
)
from ai_vision.pipelines.vision_safety_pipeline import VisionSafetyPipeline
from ai_vision.pipelines.vision_stream_runner import VisionStreamRunner
from ai_vision.pipelines.yolo_vision_provider import YOLOVisionProvider
from scripts.run_ai_vision_stream import main as run_stream_cli


class FakeFrame:
    ndim = 3

    def __init__(self, shape: tuple[int, int, int] = (4, 6, 3)) -> None:
        self.shape = shape


class FakeCapture:
    def __init__(self, frames: list[object], *, opened: bool = True) -> None:
        self.frames = list(frames)
        self.opened = opened
        self.released = False
        self.read_count = 0

    def isOpened(self) -> bool:
        return self.opened

    def get(self, _property: int) -> float:
        return 25.0

    def read(self) -> tuple[bool, object | None]:
        self.read_count += 1
        if not self.frames:
            return False, None
        return True, self.frames.pop(0)

    def release(self) -> None:
        self.released = True


class FakeCV2:
    CAP_PROP_FPS = 5

    def __init__(self, capture: FakeCapture) -> None:
        self.capture = capture
        self.arguments: list[object] = []

    def VideoCapture(self, source: object) -> FakeCapture:
        self.arguments.append(source)
        return self.capture


def test_frame_request_has_unique_id_timezone_and_source_metadata(tmp_path: Path) -> None:
    video = tmp_path / "input.mp4"
    video.write_bytes(b"fake")
    capture = FakeCapture([FakeFrame(), FakeFrame()])
    source = VideoFileSource(video, cv2_module=FakeCV2(capture))

    source.open()
    first = source.read()
    second = source.read()
    source.close()

    assert first is not None and second is not None
    assert first.source is VisionInputSource.VIDEO_FILE
    assert first.frame_index == 0 and second.frame_index == 1
    assert first.frame_id != second.frame_id
    assert datetime.fromisoformat(first.captured_at).utcoffset() is not None
    assert first.payload.image is not second.payload.image
    assert source.fps == 25.0
    assert capture.released


def test_video_eof_is_normal_and_release_is_idempotent(tmp_path: Path) -> None:
    video = tmp_path / "input.mp4"
    video.write_bytes(b"fake")
    capture = FakeCapture([FakeFrame()])
    source = VideoFileSource(video, cv2_module=FakeCV2(capture))
    source.open()

    assert source.read() is not None
    assert source.read() is None
    source.close()
    source.close()
    assert capture.released
    assert source.frame_index == 0


def test_video_missing_or_unopenable_source_is_an_error(tmp_path: Path) -> None:
    with pytest.raises(FrameSourceOpenError, match="not found"):
        VideoFileSource(tmp_path / "missing.mp4")

    video = tmp_path / "closed.mp4"
    video.write_bytes(b"fake")
    capture = FakeCapture([], opened=False)
    source = VideoFileSource(video, cv2_module=FakeCV2(capture))
    with pytest.raises(FrameSourceOpenError, match="Could not open"):
        source.open()
    assert capture.released


def test_webcam_uses_default_backend_and_reports_open_or_read_failure() -> None:
    failed_open = FakeCapture([], opened=False)
    cv2 = FakeCV2(failed_open)
    with pytest.raises(FrameSourceOpenError):
        WebcamSource(cv2_module=cv2).open()
    assert cv2.arguments == [0]
    assert failed_open.released

    read_failure = FakeCapture([])
    source = WebcamSource(2, cv2_module=FakeCV2(read_failure))
    source.open()
    with pytest.raises(FrameSourceReadError, match="failed to read"):
        source.read()
    source.close()
    assert read_failure.released


def test_webcam_capture_exception_is_reported_as_source_read_error() -> None:
    class RaisingCapture(FakeCapture):
        def read(self) -> tuple[bool, object | None]:
            raise RuntimeError("capture failure")

    capture = RaisingCapture([])
    source = WebcamSource(cv2_module=FakeCV2(capture))
    source.open()
    with pytest.raises(FrameSourceReadError, match="capture failure"):
        source.read()
    source.close()
    assert capture.released


def test_malformed_frame_is_not_treated_as_empty_detection(tmp_path: Path) -> None:
    video = tmp_path / "input.mp4"
    video.write_bytes(b"fake")
    source = VideoFileSource(
        video,
        cv2_module=FakeCV2(FakeCapture([FakeFrame((4, 6))])),
    )
    source.open()
    with pytest.raises(MalformedFrameError, match="Invalid frame"):
        source.read()
    source.close()


def test_request_rejects_malformed_memory_payload_and_frame_metadata() -> None:
    with pytest.raises(InvalidVisionInputError, match="three-dimensional"):
        FrameImagePayload(object())

    with pytest.raises(InvalidVisionInputError, match="frame_index"):
        VisionInferenceRequest(
            frame_id=str(uuid4()),
            captured_at="2026-10-06T00:00:00+00:00",
            source=VisionInputSource.WEBCAM,
            payload=FrameImagePayload(FakeFrame()),
        )


class FakeFrameSource:
    def __init__(self, count: int) -> None:
        self.requests = [
            VisionInferenceRequest(
                frame_id=str(uuid4()),
                captured_at="2026-10-06T00:00:00+00:00",
                source=VisionInputSource.WEBCAM,
                payload=FrameImagePayload(FakeFrame()),
                frame_index=index,
            )
            for index in range(count)
        ]
        self.closed = False
        self.read_count = 0

    @property
    def fps(self) -> float:
        return 30.0

    @property
    def frame_index(self) -> int:
        return self.read_count - 1

    def open(self) -> None:
        pass

    def read(self) -> VisionInferenceRequest | None:
        self.read_count += 1
        return self.requests.pop(0) if self.requests else None

    def close(self) -> None:
        self.closed = True


def _detection_result(request: VisionInferenceRequest, index: int) -> DetectionResult:
    status_by_index = ["ok", "ok", "unavailable", "error"]
    status = DetectionStatus(status_by_index[index % len(status_by_index)])
    detections = ()
    model_info = None
    error = None
    if status is DetectionStatus.OK:
        model_info = ModelInfo(provider="mock", name="stream-test")
        detections = (
            (Detection(
                class_id="bus_door",
                class_name="버스 문",
                confidence=0.8,
                bbox=BoundingBox(0.1, 0.1, 0.5, 0.5),
            ),)
            if index == 1
            else ()
        )
    else:
        error = DetectionError("SOURCE_FAILURE", "test source failure")
    return DetectionResult(
        schema_version="1.0.0",
        source=request.source.value,
        status=status,
        detections=detections,
        frame_id=request.frame_id,
        captured_at=request.captured_at,
        model_info=model_info,
        error=error,
    )


class FakeProvider:
    def __init__(self) -> None:
        self.indices: list[int] = []

    def infer(self, request: VisionInferenceRequest) -> DetectionResult:
        self.indices.append(request.frame_index or 0)
        return _detection_result(request, self.indices[-1])


class FakeBackendClient:
    def __init__(self, *, failure: Exception | None = None) -> None:
        self.calls = 0
        self.failure = failure

    def send(self, interpretation: object) -> BackendSafetyEventOutcome:
        self.calls += 1
        if self.failure is not None:
            raise self.failure
        stored = getattr(interpretation, "status") is InterpretationStatus.EVENT
        return BackendSafetyEventOutcome(
            "event" if stored else "no_event",
            stored,
            "event-1" if stored else None,
        )


def test_runner_reuses_pipeline_skips_by_source_index_and_counts_statuses() -> None:
    source = FakeFrameSource(5)
    provider = FakeProvider()
    backend = FakeBackendClient()
    pipeline = VisionSafetyPipeline(
        provider,
        SafetyInterpreter(),
        backend,  # type: ignore[arg-type]
    )
    runner = VisionStreamRunner(pipeline, clock=iter([10.0, 12.0]).__next__)

    stats = runner.run(source, frame_interval=2, max_frames=4)

    assert provider.indices == [0, 2]
    assert backend.calls == 2
    assert source.closed
    assert stats.frames_read == 4
    assert stats.frames_processed == 2
    assert stats.frames_skipped == 2
    assert stats.no_events == 1
    assert stats.unavailable == 1
    assert stats.events == stats.errors == stats.backend_stored == 0
    assert stats.elapsed_seconds == 2.0
    assert stats.processing_fps == 1.0


def test_runner_counts_events_and_detections_with_max_read_limit() -> None:
    source = FakeFrameSource(8)
    pipeline = VisionSafetyPipeline(
        FakeProvider(), SafetyInterpreter(), FakeBackendClient()  # type: ignore[arg-type]
    )
    stats = VisionStreamRunner(pipeline).run(source, max_frames=4)

    assert stats.frames_read == stats.frames_processed == 4
    assert stats.detections == 1
    assert stats.events == stats.no_events == 1
    assert stats.unavailable == stats.errors == 1
    assert stats.backend_stored == 1
    assert source.closed


def test_runner_propagates_backend_failure_and_closes_source() -> None:
    source = FakeFrameSource(2)
    error = RuntimeError("backend offline")
    pipeline = VisionSafetyPipeline(
        FakeProvider(),
        SafetyInterpreter(),
        FakeBackendClient(failure=error),  # type: ignore[arg-type]
    )

    with pytest.raises(RuntimeError, match="backend offline"):
        VisionStreamRunner(pipeline).run(source)
    assert source.closed


def test_runner_handles_keyboard_interrupt_and_closes_source() -> None:
    class InterruptingSource(FakeFrameSource):
        def read(self) -> VisionInferenceRequest:
            raise KeyboardInterrupt

    source = InterruptingSource(0)
    stats = VisionStreamRunner(
        VisionSafetyPipeline(
            FakeProvider(),
            SafetyInterpreter(),
            FakeBackendClient(),  # type: ignore[arg-type]
        )
    ).run(source)

    assert stats.interrupted
    assert stats.frames_read == stats.frames_processed == 0
    assert source.closed


def test_yolo_receives_in_memory_frame_without_temporary_file() -> None:
    class EmptyBoxes:
        xyxy: list[list[float]] = []
        cls: list[float] = []
        conf: list[float] = []

    frame = FakeFrame()
    model_path = Path("model.pt")
    captured: list[object] = []

    class Model:
        def predict(self, *, source: object, verbose: bool) -> list[object]:
            captured.append(source)
            assert verbose is False
            return [SimpleNamespace(orig_shape=(4, 6), boxes=EmptyBoxes(), names={})]

    with TemporaryDirectory() as temp_dir:
        model_path = Path(temp_dir) / "model.pt"
        model_path.write_bytes(b"stub")
        provider = YOLOVisionProvider(model_path, model_factory=lambda _: Model())
        request = VisionInferenceRequest(
            frame_id=str(uuid4()),
            captured_at="2026-10-06T00:00:00+00:00",
            source=VisionInputSource.VIDEO_FILE,
            payload=FrameImagePayload(frame),
            frame_index=0,
        )

        result = provider.infer(request)

    assert captured == [frame]
    assert result.status is DetectionStatus.OK
    assert result.source == "video_file"


@pytest.mark.parametrize(
    "arguments",
    [
        ["--source", "video", "--model", "model.pt", "--backend-url", "http://localhost"],
        [
            "--source", "video", "--video", "clip.mp4", "--camera", "0",
            "--model", "model.pt", "--backend-url", "http://localhost",
        ],
        [
            "--source", "webcam", "--video", "clip.mp4", "--model", "model.pt",
            "--backend-url", "http://localhost",
        ],
        [
            "--source", "webcam", "--camera", "-1", "--model", "model.pt",
            "--backend-url", "http://localhost",
        ],
    ],
)
def test_cli_rejects_missing_or_source_incompatible_options(arguments: list[str]) -> None:
    with pytest.raises(SystemExit):
        run_stream_cli(arguments)
