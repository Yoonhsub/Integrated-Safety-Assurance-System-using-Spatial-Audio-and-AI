"""Run one local image through YOLO, SafetyInterpreter, and the backend API."""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ai_vision.pipelines.backend_safety_event_client import (
    BackendSafetyEventClient,
    BackendSafetyEventClientError,
)
from ai_vision.pipelines.safety_interpreter import (
    SafetyInterpreter,
    SafetyInterpreterConfigurationError,
    SafetyInterpreterInputError,
)
from ai_vision.pipelines.vision_input import VisionInferenceRequest, VisionInputError, VisionInputSource
from ai_vision.pipelines.vision_provider import ProviderConfigurationError, create_vision_provider
from ai_vision.pipelines.vision_safety_pipeline import VisionSafetyPipeline


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a single local image through YOLO and send its interpretation to MOBI backend."
    )
    parser.add_argument("--model", type=Path, required=True, help="Existing local YOLO weight file.")
    parser.add_argument("--image", type=Path, required=True, help="Local image file to infer.")
    parser.add_argument("--backend-url", required=True, help="FastAPI backend base URL.")
    parser.add_argument("--timeout", type=float, default=5.0, help="Backend request timeout in seconds.")
    args = parser.parse_args()

    try:
        request = VisionInferenceRequest(
            frame_id=str(uuid4()),
            captured_at=datetime.now(timezone.utc).isoformat(),
            source=VisionInputSource.IMAGE_FILE,
            payload=args.image,
        )
        provider = create_vision_provider("yolo", model_path=args.model)
        interpreter = SafetyInterpreter()
        with BackendSafetyEventClient(args.backend_url, timeout=args.timeout) as client:
            result = VisionSafetyPipeline(provider, interpreter, client).run(request)
    except (
        BackendSafetyEventClientError,
        ProviderConfigurationError,
        SafetyInterpreterConfigurationError,
        SafetyInterpreterInputError,
        VisionInputError,
        ValueError,
    ) as exc:
        print(f"E2E failed: {exc}", file=sys.stderr)
        return 1

    print(f"frame_id={request.frame_id}")
    print(f"captured_at={request.captured_at}")
    print(f"detection_status={result.detection_status.value}")
    print(f"detection_count={result.detection_count}")
    if result.detection_result.detections:
        for detection in result.detection_result.detections:
            print(
                f"detected_class={detection.class_id} "
                f"class_name={detection.class_name} "
                f"confidence={detection.confidence:.4f}"
            )
    else:
        print("detected_class=none")
    print(f"interpretation_status={result.interpretation_status.value}")
    print(f"event={str(result.event_detected).lower()}")
    print(f"backend_sent={str(result.backend_sent).lower()}")
    print(f"backend_stored={str(result.backend_stored).lower()}")
    print(f"backend_event_id={result.backend_event_id or 'none'}")

    # A valid no_event is successful. A completed but failed/unavailable inference
    # remains visible as a nonzero CLI exit without pretending it was safe.
    return 0 if result.detection_status.value == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
