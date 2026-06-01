from __future__ import annotations

import os
import sys
from pathlib import Path

from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parents[3]
BACKEND_ROOT = ROOT / "backend" / "api"
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.services.odsay_client import OdsayClient, OdsayUnavailableError  # noqa: E402


def main() -> int:
    load_dotenv(ROOT / ".env", override=False)
    if not os.getenv("ODSAY_API_KEY", "").strip():
        print("ODsay smoke skipped: set ODSAY_API_KEY in the backend .env first.")
        return 0
    if os.getenv("ODSAY_ENABLED", "false").strip().lower() not in {"true", "1", "yes", "on"}:
        print("ODsay smoke skipped: set ODSAY_ENABLED=true in the backend .env first.")
        return 0

    # Example: Sachang intersection in Cheongju -> Sangdang Sanseong.
    client = OdsayClient()
    try:
        result = client.search_public_transit_path(
            origin_lat=36.6359,
            origin_lng=127.4596,
            destination_lat=36.6612,
            destination_lng=127.5348,
        )
    except OdsayUnavailableError as exc:
        print(f"ODsay smoke failed safely: {exc}")
        return 1

    paths = result.raw_response.get("result", {}).get("path", [])
    print(f"ODsay smoke PASS: received {len(paths) if isinstance(paths, list) else 0} path candidates.")
    if isinstance(paths, list):
        for index, path in enumerate(paths[:3], start=1):
            info = path.get("info", {}) if isinstance(path, dict) else {}
            sub_paths = path.get("subPath", []) if isinstance(path, dict) else []
            print(
                f"- candidate {index}: totalTime={info.get('totalTime')}, "
                f"busTransitCount={info.get('busTransitCount')}, legs={len(sub_paths) if isinstance(sub_paths, list) else 0}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
