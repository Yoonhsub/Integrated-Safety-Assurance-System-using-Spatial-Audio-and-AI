"""Sequentially feed frame requests through the existing single-frame pipeline."""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable

from ai_vision.pipelines.frame_sources import FrameSource
from ai_vision.pipelines.safety_interpreter import InterpretationStatus
from ai_vision.pipelines.vision_safety_pipeline import VisionSafetyPipeline


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


class VisionStreamRunner:
    """Run one source sequentially and always release it, including on Ctrl+C."""

    def __init__(
        self,
        pipeline: VisionSafetyPipeline,
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
        try:
            source.open()
            while max_frames is None or frames_read < max_frames:
                request = source.read()
                if request is None:
                    break
                frames_read += 1
                source_index = request.frame_index
                index = source_index if source_index is not None else frames_read - 1
                if index % frame_interval:
                    frames_skipped += 1
                    continue

                result = self.pipeline.run(request)
                frames_processed += 1
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
        )
