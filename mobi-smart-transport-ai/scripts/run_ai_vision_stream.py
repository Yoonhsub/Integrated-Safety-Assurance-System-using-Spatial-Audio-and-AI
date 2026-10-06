"""Process a local video or webcam as sequential AI Vision frame requests."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ai_vision.pipelines.backend_safety_event_client import (
    BackendSafetyEventClient,
    BackendSafetyEventClientError,
)
from ai_vision.pipelines.frame_sources import (
    FrameSourceError,
    VideoFileSource,
    WebcamSource,
)
from ai_vision.pipelines.safety_interpreter import SafetyInterpreter
from ai_vision.pipelines.vision_provider import ProviderConfigurationError, create_vision_provider
from ai_vision.pipelines.vision_safety_pipeline import VisionSafetyPipeline
from ai_vision.pipelines.vision_stream_runner import VisionStreamRunner


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run each selected video/webcam frame through the AI Vision pipeline."
    )
    parser.add_argument("--source", choices=("video", "webcam"), required=True)
    parser.add_argument("--video", type=Path, help="Required only when --source video.")
    parser.add_argument("--camera", type=int, help="Webcam index (default: 0).")
    parser.add_argument(
        "--model",
        type=Path,
        required=True,
        help="Existing local YOLO weight file.",
    )
    parser.add_argument("--backend-url", required=True, help="FastAPI backend base URL.")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument(
        "--frame-interval",
        type=int,
        default=1,
        help="Process one frame, then skip N-1 frames (default: 1, process all).",
    )
    parser.add_argument(
        "--max-frames",
        type=int,
        help="Stop after reading this many source frames, including skipped frames.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.frame_interval < 1:
        parser.error("--frame-interval must be at least 1")
    if args.max_frames is not None and args.max_frames < 1:
        parser.error("--max-frames must be at least 1")
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    if args.camera is not None and args.camera < 0:
        parser.error("--camera must be a non-negative index")

    try:
        if args.source == "video":
            if args.video is None:
                parser.error("--video is required when --source video")
            if args.camera is not None:
                parser.error("--camera is only valid when --source webcam")
            source = VideoFileSource(args.video)
        else:
            if args.video is not None:
                parser.error("--video is only valid when --source video")
            source = WebcamSource(0 if args.camera is None else args.camera)
        provider = create_vision_provider("yolo", model_path=args.model)
        interpreter = SafetyInterpreter()
        with BackendSafetyEventClient(args.backend_url, timeout=args.timeout) as client:
            statistics = VisionStreamRunner(
                VisionSafetyPipeline(provider, interpreter, client)
            ).run(
                source,
                frame_interval=args.frame_interval,
                max_frames=args.max_frames,
            )
    except (
        BackendSafetyEventClientError,
        FrameSourceError,
        ProviderConfigurationError,
        ValueError,
    ) as exc:
        print(f"AI Vision stream failed: {exc}", file=sys.stderr)
        return 1

    print(f"source={source.source.value}")
    print(f"source_fps={source.fps if source.fps is not None else 'unknown'}")
    print(f"frames_read={statistics.frames_read}")
    print(f"frames_processed={statistics.frames_processed}")
    print(f"frames_skipped={statistics.frames_skipped}")
    print(f"detection_count={statistics.detections}")
    print(f"event_count={statistics.events}")
    print(f"no_event_count={statistics.no_events}")
    print(f"unavailable_count={statistics.unavailable}")
    print(f"error_count={statistics.errors}")
    print(f"backend_stored_count={statistics.backend_stored}")
    print(f"elapsed_seconds={statistics.elapsed_seconds:.3f}")
    print(f"processing_fps={statistics.processing_fps:.3f}")
    print(f"interrupted={str(statistics.interrupted).lower()}")
    return 0 if statistics.interrupted or not (statistics.unavailable or statistics.errors) else 1


if __name__ == "__main__":
    raise SystemExit(main())
