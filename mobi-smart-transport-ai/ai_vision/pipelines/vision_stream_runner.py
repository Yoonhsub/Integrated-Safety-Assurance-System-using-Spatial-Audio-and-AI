"""Sequentially feed frame requests through the existing single-frame pipeline."""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable

from ai_vision.pipelines.frame_sources import FrameSource
from ai_vision.pipelines.safety_interpreter import InterpretationStatus
from ai_vision.pipelines.vision_safety_pipeline import VisionSafetyPipeline
from ai_vision.pipelines.vision_producer_client import VisionEvent, ProducerError
from ai_vision.pipelines.safety_interpreter import SafetyInterpreter
from ai_vision.pipelines.vision_input import VisionInputSource


@dataclass(frozen=True)
class ProducerFrameResult:
    detection_count: int
    interpretation_status: InterpretationStatus
    receipt: dict | None
    backend_stored: bool = False
    expired: bool = False


class ProducerStreamPipeline:
    """Sequential v2 submission; transport errors stop the runner and release input.

    Source timestamps are host-read times, including replay playback. They are
    never attested camera exposure times. Server binding determines live/replay.
    """

    def __init__(self, provider, client, binding):
        import copy
        self.provider, self.client = provider, client
        self.binding = copy.deepcopy(binding)
        self.interpreter = SafetyInterpreter()
        self.client.attach_binding(self.binding)
        self.last_event = None
        self.last_receipt = None
        self.expired_frames = 0
        self.last_http_seconds = 0.0

    def run(self, request):
        expected = {VisionInputSource.VIDEO_FILE: "replay", VisionInputSource.WEBCAM: "live"}
        if expected.get(request.source) != self.binding["sourceType"]:
            raise ProducerError("STREAM_SOURCE_BINDING_MISMATCH")
        detection = self.provider.infer(request)
        interpretation = self.interpreter.interpret(detection)
        self.last_event = VisionEvent.create(
            self.binding, detection, frame_index=request.frame_index,
            captured_at=request.captured_at, capture_clock="host_read",
        )
        self.last_receipt = None
        started = time.perf_counter()
        try:
            self.last_receipt = self.client.send(self.last_event)
        except ProducerError as exc:
            # Only certainly unsent expiration can advance to the next frame.
            # Pending/uncertain delivery must stop, preserving Client's barrier.
            if exc.code != "EVENT_EXPIRED" or exc.uncertain:
                raise
            self.expired_frames += 1
            return ProducerFrameResult(len(detection.detections), interpretation.status, None, expired=True)
        finally:
            self.last_http_seconds = time.perf_counter() - started
        return ProducerFrameResult(len(detection.detections), interpretation.status, self.last_receipt)


@dataclass(frozen=True)
class VisionStreamStatistics:
    frames_read: int
    frames_processed: int
    frames_skipped: int
    detections: int
    events: int
    no_events: int
    unavailable: int
    errors: int
    backend_stored: int
    elapsed_seconds: float
    processing_fps: float
    interrupted: bool = False
    expired: int = 0
    submitted: int = 0


class VisionStreamRunner:
    """Run one source sequentially and always release it, including on Ctrl+C."""

    def __init__(
        self,
        pipeline: VisionSafetyPipeline | ProducerStreamPipeline,
        *,
        clock: Callable[[], float] = time.perf_counter,
    ) -> None:
        self.pipeline = pipeline
        self._clock = clock

    def run(
        self,
        source: FrameSource,
        *,
        frame_interval: int = 1,
        max_frames: int | None = None,
        on_frame: Callable | None = None,
    ) -> VisionStreamStatistics:
        """Process every Nth acquired frame; max_frames limits source reads."""
        if (
            isinstance(frame_interval, bool)
            or not isinstance(frame_interval, int)
            or frame_interval < 1
        ):
            raise ValueError("frame_interval must be a positive integer.")
        if max_frames is not None and (
            isinstance(max_frames, bool) or not isinstance(max_frames, int) or max_frames < 1
        ):
            raise ValueError("max_frames must be a positive integer when provided.")

        started = self._clock()
        frames_read = frames_processed = frames_skipped = 0
        detections = events = no_events = unavailable = errors = backend_stored = 0
        interrupted = False
        expired = submitted = 0
        try:
            source.open()
            while max_frames is None or frames_read < max_frames:
                frame_started = time.perf_counter()
                request = source.read()
                read_seconds = time.perf_counter() - frame_started
                if request is None:
                    break
                frames_read += 1
                source_index = request.frame_index
                index = source_index if source_index is not None else frames_read - 1
                if index % frame_interval:
                    frames_skipped += 1
                    continue

                result = self.pipeline.run(request)
                if on_frame is not None:
                    on_frame(request, result, read_seconds, time.perf_counter() - frame_started)
                frames_processed += 1
                if getattr(result, "expired", False):
                    expired += 1
                elif getattr(result, "receipt", None) is not None:
                    submitted += 1
                detections += result.detection_count
                status = result.interpretation_status
                if status is InterpretationStatus.EVENT:
                    events += 1
                elif status is InterpretationStatus.NO_EVENT:
                    no_events += 1
                elif status is InterpretationStatus.UNAVAILABLE:
                    unavailable += 1
                elif status is InterpretationStatus.ERROR:
                    errors += 1
                if result.backend_stored:
                    backend_stored += 1
        except KeyboardInterrupt:
            interrupted = True
        finally:
            source.close()

        elapsed = max(0.0, self._clock() - started)
        return VisionStreamStatistics(
            frames_read=frames_read,
            frames_processed=frames_processed,
            frames_skipped=frames_skipped,
            detections=detections,
            events=events,
            no_events=no_events,
            unavailable=unavailable,
            errors=errors,
            backend_stored=backend_stored,
            elapsed_seconds=elapsed,
            processing_fps=(frames_processed / elapsed if elapsed > 0 else 0.0),
            interrupted=interrupted,
            expired=expired,
            submitted=submitted,
        )
