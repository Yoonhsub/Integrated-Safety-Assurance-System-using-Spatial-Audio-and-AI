"""Opt-in local YOLO single-image smoke; never downloads weights or images."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ai_vision.pipelines.vision_input import VisionInferenceRequest, VisionInputSource
from ai_vision.pipelines.yolo_vision_provider import YOLOVisionProvider


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run one image with an explicitly prepared local YOLO weight file."
    )
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    args = parser.parse_args()

    request = VisionInferenceRequest(
        frame_id=str(uuid4()),
        captured_at=datetime.now(timezone.utc).isoformat(),
        source=VisionInputSource.IMAGE_FILE,
        payload=args.image,
    )
    result = YOLOVisionProvider(args.model_path).infer(request)
    print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))
    return 0 if result.status.value == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
