from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
BACKEND_ROOT = ROOT / "backend" / "api"
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402
from app.services.firebase_client import get_firebase_client  # noqa: E402


def assert_status(response, expected: int, label: str) -> dict:
    if response.status_code != expected:
        raise AssertionError(f"{label} expected {expected}, got {response.status_code}: {response.text}")
    return response.json()


def main() -> int:
    client = TestClient(app)
    firebase = get_firebase_client()
    firebase.clear_mock_store()

    health = assert_status(client.get("/health"), 200, "GET /health")
    if health.get("status") != "ok":
        raise AssertionError(f"unexpected health body: {health}")

    arrivals = assert_status(client.get("/bus-info/stops/mock-stop-001/arrivals"), 200, "GET /bus-info")
    if arrivals.get("stopId") != "mock-stop-001" or not isinstance(arrivals.get("arrivals"), list):
        raise AssertionError(f"unexpected bus arrivals body: {arrivals}")

    created = assert_status(
        client.post(
            "/ride-requests",
            json={
                "userId": "smoke-user",
                "stopId": "mock-stop-001",
                "routeId": "MOCK-502",
                "busNo": "502",
                "targetDriverId": "smoke-driver",
            },
        ),
        200,
        "POST /ride-requests",
    )
    request_id = created["requestId"]

    driver_list = assert_status(
        client.get("/driver/ride-requests", params={"driverId": "smoke-driver"}),
        200,
        "GET /driver/ride-requests",
    )
    if request_id not in {item["requestId"] for item in driver_list["requests"]}:
        raise AssertionError(f"created request not found in driver list: {driver_list}")

    accepted = assert_status(
        client.patch(f"/driver/ride-requests/{request_id}/status", json={"status": "ACCEPTED"}),
        200,
        "PATCH /driver/ride-requests/{requestId}/status",
    )
    if accepted.get("status") != "ACCEPTED":
        raise AssertionError(f"unexpected accepted body: {accepted}")

    print("Backend smoke integration: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
