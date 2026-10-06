"""Opt-in smoke check for cross-process AI Vision event ingestion."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ai_vision.pipelines.backend_safety_event_client import BackendSafetyEventClient
from ai_vision.pipelines.detection_result import DetectionResult
from ai_vision.pipelines.safety_interpreter import InterpretationStatus, SafetyInterpreter


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send a mock AI Vision interpretation to a running MOBI backend."
    )
    parser.add_argument(
        "--backend-url",
        default=os.getenv("MOBI_BACKEND_URL", "http://127.0.0.1:8000"),
        help="Backend base URL (default: MOBI_BACKEND_URL or localhost:8000).",
    )
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    fixture_path = ROOT / "ai_vision" / "pipelines" / "fixtures" / "mock_detection_results.json"
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    result = DetectionResult.from_dict(fixture["results"][0])
    interpretation = SafetyInterpreter().interpret(result)
    if interpretation.status is not InterpretationStatus.EVENT:
        raise RuntimeError("The selected fixture must produce an AI Vision event.")

    with BackendSafetyEventClient(args.backend_url, timeout=args.timeout) as client:
        outcome = client.send(interpretation)
        if outcome.status != "event" or not outcome.stored or not outcome.event_id:
            raise RuntimeError(f"Backend did not store the event: {outcome!r}")
        recent = client.recent_events()
        if not any(item.get("eventId") == outcome.event_id for item in recent):
            raise RuntimeError(
                f"Stored event {outcome.event_id!r} was not present in recent events."
            )

    print(f"PASS: backend stored AI Vision event {outcome.event_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
