from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from fastapi.testclient import TestClient

from app.main import app
from app.services import v3_beacon_service


client = TestClient(app)


def setup_function() -> None:
    v3_beacon_service._latest_state.clear()
    v3_beacon_service._rssi_history.clear()
    v3_beacon_service._observations.clear()


@pytest.fixture(autouse=True)
def demo_mode(monkeypatch):
    monkeypatch.setenv("USE_MOCK_DATA", "true")


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


def test_get_latest_after_timeout_returns_beacon_lost(monkeypatch) -> None:
    observed = datetime.now(timezone.utc)
    old_timestamp = observed.isoformat()
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
    monkeypatch.setattr(v3_beacon_service, "_utc_now", lambda: observed + timedelta(seconds=10))
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
    base_timestamp = datetime.now(timezone.utc) - timedelta(seconds=2)
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

@pytest.fixture
def clock(monkeypatch):
    now = datetime.now(timezone.utc)
    state = [now, 100.0]
    monkeypatch.setattr(v3_beacon_service, "_utc_now", lambda: state[0])
    monkeypatch.setattr(v3_beacon_service.time, "monotonic", lambda: state[1])
    return state


def _payload(stamp, **overrides):
    return dict(sessionId="freshness", deviceId="collector", beaconId="MOBI_BUS_502_TARGET",
                rssi=-55, source="MANUAL_TEST", timestamp=stamp.isoformat(), **overrides)


def _post(payload):
    response = client.post("/api/v3/beacon/ingest", json=payload)
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.parametrize("identity", ["NOT_TARGET", "MOBI_BUS_502_TARGET", "C3:00:00:5C:B9:47"])
def test_real_identity_is_unverified_even_with_claimed_bus(identity, clock):
    p = _payload(clock[0], busId="BUS_502_NOW", routeNo="502", macAddress="C3:00:00:5C:B9:47")
    p.update(beaconId=identity, source="REAL_BLE")
    result = _post(p)
    assert result["decision"] == "NO_BEACON"
    assert result["phase"] == "WAITING_FOR_BUS"
    assert result["confidence"] == 0
    assert "UNVERIFIED_IDENTITY" in result["warnings"][0]


@pytest.mark.parametrize("change", [{"beaconId": "NOT_TARGET"}, {"busId": "BUS_100"}, {"routeNo": "100"}])
def test_demo_identity_requires_exact_consistent_fixture(change, clock):
    p = _payload(clock[0]); p.update(change)
    assert _post(p)["phase"] == "WAITING_FOR_BUS"


def test_live_server_never_accepts_demo_identity(monkeypatch, clock):
    monkeypatch.setenv("USE_MOCK_DATA", "false")
    assert _post(_payload(clock[0]))["decision"] == "NO_BEACON"


@pytest.mark.parametrize("offset", [-10, 1])
def test_stale_or_future_first_observation_does_not_create_state(offset, clock):
    result = _post(_payload(clock[0] + timedelta(seconds=offset)))
    assert result["phase"] == "WAITING_FOR_BUS"
    assert v3_beacon_service.get_latest_state("freshness") is None


def test_naive_timestamp_is_rejected():
    response = client.post("/api/v3/beacon/ingest", json=_payload(datetime(2026, 1, 1)))
    assert response.status_code == 422


def test_timezone_offset_normalized_to_utc(clock):
    result = _post(_payload(clock[0].astimezone(timezone(timedelta(hours=9)))))
    assert datetime.fromisoformat(result["lastUpdatedAt"].replace("Z", "+00:00")) == clock[0]


def test_duplicate_and_reverse_order_cannot_replace_newer_state_or_extend_deadline(clock):
    stamp = clock[0]
    first = _post(_payload(stamp))
    deadline = v3_beacon_service._observations["freshness"][1]
    for delta in [0, -1]:
        p = _payload(stamp + timedelta(seconds=delta)); p["rssi"] = -100
        result = _post(p)
        assert result["decision"] == first["decision"]
        assert "DUPLICATE_OR_OUT_OF_ORDER" in result["warnings"][-1]
        assert v3_beacon_service._observations["freshness"][1] == deadline
    clock[1] += 6
    # Wall clock unchanged: monotonic expiry alone must revoke boarding.
    latest = v3_beacon_service.get_latest_state("freshness")
    assert latest.decision.value == "BEACON_LOST"
    assert latest.lastUpdatedAt == stamp
    assert _post(_payload(stamp))["decision"] == "BEACON_LOST"
    clock[0] += timedelta(seconds=1)
    assert _post(_payload(clock[0]))["decision"] == "TARGET_BUS_NEAR"


def test_unstable_and_unknown_revoke_previous_boarding(clock):
    _post(_payload(clock[0]))
    clock[0] += timedelta(seconds=1)
    p = _payload(clock[0]); p["rssi"] = -90
    result = _post(p)
    assert result["decision"] == "SIGNAL_UNSTABLE"
    assert result["phase"] == "WAITING_FOR_BUS"
    clock[0] += timedelta(seconds=1)
    p = _payload(clock[0]); p.update(source="REAL_BLE")
    assert _post(p)["phase"] == "WAITING_FOR_BUS"


def test_other_beacons_do_not_share_rssi_history(clock):
    p = _payload(clock[0]); p["rssi"] = -90
    _post(p)
    clock[0] += timedelta(seconds=1)
    p = _payload(clock[0]); p["beaconId"] = "MOBI_BUS_100_WRONG"
    assert _post(p)["decision"] == "WRONG_BUS_NEAR"


def test_reacquisition_after_gap_resets_unstable_comparison(clock):
    p = _payload(clock[0]); p["rssi"] = -90
    _post(p)
    clock[0] += timedelta(seconds=6); clock[1] += 6
    assert _post(_payload(clock[0]))["decision"] == "TARGET_BUS_NEAR"


def test_future_or_stale_does_not_overwrite_valid_state(clock):
    first = _post(_payload(clock[0]))
    for delta in [10, -10]:
        result = _post(_payload(clock[0] + timedelta(seconds=delta)))
        assert result["lastUpdatedAt"] == first["lastUpdatedAt"]
        assert result["decision"] == first["decision"]


def test_wall_clock_reversal_revokes_state(clock):
    _post(_payload(clock[0]))
    clock[0] -= timedelta(seconds=1)
    assert v3_beacon_service.get_latest_state("freshness").decision.value == "BEACON_LOST"


def test_ingest_does_not_enable_live_boarding_or_bind_selected_vehicle(clock):
    from app.services.v3_guidance_store import v3_guidance_store
    from app.schemas.v3 import GuidanceState

    session = v3_guidance_store.create(session_id="freshness")
    session.selected_route_no = "502"
    session.selected_route_id = "selected-route"
    session.selected_stop_id = "selected-stop"
    session.target_bus_id = "SELECTED_VEHICLE"
    session.state = GuidanceState.WAITING_FOR_BUS
    try:
        p = _payload(clock[0], busId="SELECTED_VEHICLE", routeNo="502")
        p["source"] = "REAL_BLE"
        assert _post(p)["decision"] == "NO_BEACON"
        assert session.last_decision is None
        response = client.post("/agent/converse", json={
            "sessionId": "freshness", "wakeWord": "자비스",
            "utterance": "자비스, 지금 앞에 온 버스 타도 돼?", "mode": "live",
        })
        assert response.status_code == 200
        assert response.json()["intent"] == "ASK_CAN_BOARD_CURRENT_BUS"
        assert response.json()["state"] == "WAITING_FOR_BUS"
        assert "확인하지 못했어요" in response.json()["message"]
        assert response.json()["ttsMode"] == "SAFETY_LOCAL"
    finally:
        v3_guidance_store.clear()
