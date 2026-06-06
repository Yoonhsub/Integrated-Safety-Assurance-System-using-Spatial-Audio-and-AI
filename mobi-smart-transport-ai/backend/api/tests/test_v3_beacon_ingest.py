from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from app.main import app
from app.services import v3_beacon_service


client = TestClient(app)


def setup_function() -> None:
    v3_beacon_service._latest_state.clear()
    v3_beacon_service._rssi_history.clear()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def test_v3_beacon_ingest_routes_are_registered() -> None:
    current_routes = {
        (route.path, method)
        for route in app.routes
        for method in getattr(route, "methods", set())
    }
    for path, method in {
        ("/api/v3/beacon/ingest", "POST"),
        ("/api/v3/beacon/latest", "GET"),
        ("/api/v3/beacon/reset", "POST"),
    }:
        assert (path, method) in current_routes


def test_ingest_target_near_returns_boarding_confirmation() -> None:
    response = client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "demo-session",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "busId": "BUS_502_NOW",
            "routeNo": "502",
            "rssi": -55,
            "distanceMeters": 2.0,
            "source": "MANUAL_TEST",
            "timestamp": _now_iso(),
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "TARGET_BUS_NEAR"
    assert body["proximity"] == "NEAR"
    assert body["phase"] == "BOARDING_CONFIRMATION"
    assert body["cueType"] == "TARGET_BUS_NEAR"
    assert body["scriptLineId"] == "bus_stopped"


def test_ingest_target_mid_returns_waiting_for_bus() -> None:
    response = client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "demo-session",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "busId": "BUS_502_NOW",
            "routeNo": "502",
            "rssi": -70,
            "distanceMeters": 6.0,
            "source": "MANUAL_TEST",
            "timestamp": _now_iso(),
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "TARGET_BUS_MID"
    assert body["proximity"] == "MID"
    assert body["phase"] == "WAITING_FOR_BUS"
    assert body["cueType"] == "TARGET_BUS_MID"
    assert body["scriptLineId"] == "bus_approaching"


def test_ingest_target_far_returns_target_bus_far() -> None:
    response = client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "demo-session",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "rssi": -80,
            "distanceMeters": 15.0,
            "source": "MANUAL_TEST",
            "timestamp": _now_iso(),
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "TARGET_BUS_FAR"
    assert body["proximity"] == "FAR"
    assert body["cueType"] == "TARGET_BUS_FAR"


def test_ingest_wrong_beacon_near_returns_wrong_bus_warning() -> None:
    response = client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "demo-session",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_100_WRONG",
            "busId": "BUS_100",
            "routeNo": "100",
            "rssi": -58,
            "distanceMeters": 3.0,
            "source": "MANUAL_TEST",
            "timestamp": _now_iso(),
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "WRONG_BUS_NEAR"
    assert body["cueType"] == "WRONG_BUS_NEAR"
    assert body["scriptLineId"] == "wrong_bus_warning"


def test_get_latest_before_ingest_returns_404() -> None:
    response = client.get(
        "/api/v3/beacon/latest",
        params={"sessionId": "never-ingested"},
    )
    assert response.status_code == 404


def test_get_latest_returns_recent_ingest() -> None:
    client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "latest-test",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "rssi": -55,
            "source": "MANUAL_TEST",
            "timestamp": _now_iso(),
        },
    )
    response = client.get(
        "/api/v3/beacon/latest",
        params={"sessionId": "latest-test"},
    )
    assert response.status_code == 200
    assert response.json()["decision"] == "TARGET_BUS_NEAR"


def test_reset_clears_session_state() -> None:
    client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "reset-test",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "rssi": -55,
            "source": "MANUAL_TEST",
            "timestamp": _now_iso(),
        },
    )
    reset_response = client.post(
        "/api/v3/beacon/reset",
        params={"sessionId": "reset-test"},
    )
    assert reset_response.status_code == 200
    assert reset_response.json()["status"] == "reset"
    
    after = client.get(
        "/api/v3/beacon/latest",
        params={"sessionId": "reset-test"},
    )
    assert after.status_code == 404


def test_get_latest_after_timeout_returns_beacon_lost() -> None:
    old_timestamp = (
        datetime.now(timezone.utc) - timedelta(seconds=10)
    ).isoformat()
    client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "lost-test",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "rssi": -60,
            "source": "MANUAL_TEST",
            "timestamp": old_timestamp,
        },
    )
    response = client.get(
        "/api/v3/beacon/latest",
        params={"sessionId": "lost-test"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "BEACON_LOST"
    assert body["proximity"] == "LOST"
    assert body["scriptLineId"] == "signal_lost"
    assert len(body["warnings"]) > 0


def test_ingest_with_rssi_spike_returns_signal_unstable() -> None:
    base_timestamp = datetime.now(timezone.utc)
    client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "unstable-test",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "rssi": -60,
            "source": "MANUAL_TEST",
            "timestamp": base_timestamp.isoformat(),
        },
    )
    response = client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "unstable-test",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "rssi": -85,
            "source": "MANUAL_TEST",
            "timestamp": (base_timestamp + timedelta(seconds=1)).isoformat(),
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["decision"] == "SIGNAL_UNSTABLE"
    assert body["proximity"] == "UNSTABLE"


def test_ingest_missing_required_field_returns_422() -> None:
    response = client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "demo-session",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "source": "MANUAL_TEST",
            "timestamp": _now_iso(),
        },
    )
    assert response.status_code == 422


def test_ingest_invalid_source_returns_422() -> None:
    response = client.post(
        "/api/v3/beacon/ingest",
        json={
            "sessionId": "demo-session",
            "deviceId": "pytest-device",
            "beaconId": "MOBI_BUS_502_TARGET",
            "rssi": -55,
            "source": "INVALID_SOURCE",
            "timestamp": _now_iso(),
        },
    )
    assert response.status_code == 422