"""main-compatible local observation boundary and lifecycle regressions."""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services import beacon_observation_store as observations
from app.services.beacon_registry import BeaconAssignment, BeaconRegistry
from app.services.v3_guidance_store import v3_guidance_store


class ClientAddress:
    def __init__(self, host):
        self.host = host

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            scope = {**scope, "client": (self.host, 50000)}
        await app(scope, receive, send)


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("BEACON_OBSERVATIONS_LOCAL", "1")
    v3_guidance_store.clear()
    with TestClient(ClientAddress("127.0.0.1")) as value:
        yield value
    v3_guidance_store.clear()


@pytest.fixture
def clock(monkeypatch):
    value = [datetime.now(timezone.utc), 100.0]
    monkeypatch.setattr(observations, "_utc_now", lambda: value[0])
    monkeypatch.setattr(observations.time, "monotonic", lambda: value[1])
    monkeypatch.setattr(observations, "beacon_registry", BeaconRegistry())
    return value


def create(client, sid="local-observation"):
    response = client.post("/guidance/session", json={"sessionId": sid})
    assert response.status_code == 200, response.text
    return response.json()["sessionId"]


def collect(client, sid, clock, **changes):
    body = dict(sessionId=sid, deviceId="collector", beaconId="beacon-1", rssi=-60,
                source="REAL_BLE", timestamp=clock[0].isoformat())
    body.update(changes)
    response = client.post("/api/v3/beacon/ingest", json=body)
    assert response.status_code == 200, response.text
    return response.json()


def preview(client, sid):
    response = client.get("/api/v3/beacon/observations", params={"sessionId": sid})
    assert response.status_code == 200, response.text
    assert response.headers["Cache-Control"] == "no-store"
    return response.json()


def test_measurements_and_configured_labels_do_not_mutate_guidance(client, clock, monkeypatch):
    sid = create(client)
    monkeypatch.setattr(observations, "beacon_registry", BeaconRegistry(
        {"beacon-1": BeaconAssignment("configured-vehicle", "502")}, configured=True))
    collect(client, sid, clock, busId="client-claim")
    result = preview(client, sid)
    assert result["status"] == "AVAILABLE"
    assert result["guidanceEligible"] is False
    assert result["shouldSpeak"] is False
    assert result["shouldPlaySpatialCue"] is False
    item = result["observations"][0]
    assert item["configuredBusId"] == "configured-vehicle"
    assert item["vehicleIdentityVerified"] is False
    state = client.get("/guidance/state", params={"sessionId": sid}).json()
    assert state["state"] == "IDLE"
    assert state["lastDecision"] is None
    assert state["targetBus"] is None


def test_disabled_feature_exposes_no_observations(client, clock, monkeypatch):
    sid = create(client)
    monkeypatch.delenv("BEACON_OBSERVATIONS_LOCAL")
    collect(client, sid, clock)
    response = client.get("/api/v3/beacon/observations", params={"sessionId": sid})
    assert response.status_code == 404
    assert sid not in observations.beacon_observation_store._entries


@pytest.mark.parametrize("host", ["203.0.113.5", "192.168.1.20", "testclient"])
def test_nonloopback_and_forwarded_headers_cannot_enable_observations(client, clock, host):
    sid = create(client)
    with TestClient(ClientAddress(host)) as remote:
        collect(remote, sid, clock)
        response = remote.get("/api/v3/beacon/observations", params={"sessionId": sid},
                              headers={"X-Forwarded-For": "127.0.0.1"})
        assert response.status_code == 403
    assert preview(client, sid)["observations"] == []


def test_ipv6_loopback_is_allowed(client, clock):
    sid = create(client)
    with TestClient(ClientAddress("::1")) as ipv6:
        collect(ipv6, sid, clock)
        assert preview(ipv6, sid)["observations"]


def test_unknown_session_is_not_created_by_preview_or_ingest(client, clock):
    sid = "not-created"
    collect(client, sid, clock)
    response = client.get("/api/v3/beacon/observations", params={"sessionId": sid})
    assert response.status_code == 404
    assert sid not in v3_guidance_store._sessions
    assert sid not in observations.beacon_observation_store._entries


def test_multiple_beacons_at_same_time_are_independent(client, clock):
    sid = create(client)
    collect(client, sid, clock)
    collect(client, sid, clock, beaconId="beacon-2", rssi=-80)
    assert [x["beaconId"] for x in preview(client, sid)["observations"]] == ["beacon-1", "beacon-2"]


def test_duplicate_and_reverse_order_never_extend_deadline_or_resurrect(client, clock):
    sid = create(client)
    collect(client, sid, clock)
    stamp = clock[0]
    clock[0] += timedelta(seconds=1)
    clock[1] += 1
    for delta in (0, -1):
        collect(client, sid, clock, timestamp=(stamp + timedelta(seconds=delta)).isoformat(), rssi=-90)
    assert preview(client, sid)["observations"][0]["rssi"] == -60
    assert preview(client, sid)["observations"][0]["validForSeconds"] == 4
    clock[1] += 5
    assert preview(client, sid)["observations"] == []
    collect(client, sid, clock, timestamp=stamp.isoformat())
    assert preview(client, sid)["observations"] == []


def test_unrelated_radio_does_not_extend_an_old_beacon(client, clock):
    sid = create(client)
    collect(client, sid, clock)
    clock[0] += timedelta(seconds=3)
    clock[1] += 3
    collect(client, sid, clock, beaconId="new-beacon")
    clock[0] += timedelta(seconds=3)
    clock[1] += 3
    assert [x["beaconId"] for x in preview(client, sid)["observations"]] == ["new-beacon"]


@pytest.mark.parametrize("offset", [-6, 1])
def test_stale_and_future_samples_do_not_create_preview(client, clock, offset):
    sid = create(client)
    collect(client, sid, clock, timestamp=(clock[0] + timedelta(seconds=offset)).isoformat())
    assert preview(client, sid)["status"] == "EMPTY"


def test_clock_reversal_revokes_observations(client, clock):
    sid = create(client)
    collect(client, sid, clock)
    clock[0] -= timedelta(seconds=1)
    assert preview(client, sid)["observations"] == []


@pytest.mark.parametrize("field", ["targetBusId", "routeNo", "stopId"])
def test_route_context_change_clears_observations(client, clock, field):
    sid = create(client)
    collect(client, sid, clock)
    response = client.post("/guidance/event", json={
        "sessionId": sid, "event": "ROUTE_SELECTED", "payload": {field: "new-value"}})
    assert response.status_code == 200
    assert preview(client, sid)["observations"] == []
    assert client.get("/api/v3/beacon/latest", params={"sessionId": sid}).status_code == 404


@pytest.mark.parametrize("endpoint", ["/guidance/reset", "/api/v3/beacon/reset"])
def test_reset_isolated_to_one_session(client, clock, endpoint):
    sid, other = create(client), create(client, "other")
    collect(client, sid, clock)
    collect(client, other, clock)
    if endpoint == "/guidance/reset":
        response = client.post(endpoint, json={"sessionId": sid, "event": "RESET"})
    else:
        response = client.post(endpoint, params={"sessionId": sid})
    assert response.status_code == 200
    assert preview(client, sid)["observations"] == []
    assert preview(client, other)["observations"]


def test_boarded_session_cannot_show_or_collect_observations(client, clock):
    sid = create(client)
    collect(client, sid, clock)
    for event in ("ROUTE_SELECTED", "WAITING_FOR_BUS", "BOARDING_CONFIRMATION", "BOARDED"):
        response = client.post("/guidance/event", json={"sessionId": sid, "event": event})
        assert response.status_code == 200
    collect(client, sid, clock)
    assert client.get("/api/v3/beacon/observations", params={"sessionId": sid}).status_code == 409
    assert sid not in observations.beacon_observation_store._entries


def test_active_capacity_and_reacquisition(client, clock, monkeypatch):
    monkeypatch.setattr(observations, "MAX_OBSERVATIONS_PER_SESSION", 2)
    sid = create(client)
    for name in ("a", "b", "c"):
        collect(client, sid, clock, beaconId=name)
    assert len(preview(client, sid)["observations"]) == 2
    clock[0] += timedelta(seconds=6)
    clock[1] += 6
    collect(client, sid, clock, beaconId="c")
    assert [x["beaconId"] for x in preview(client, sid)["observations"]] == ["c"]


def test_seen_capacity_and_session_recreation(client, clock, monkeypatch):
    monkeypatch.setattr(observations, "MAX_SEEN_KEYS_PER_SESSION", 1)
    sid = create(client)
    collect(client, sid, clock, beaconId="a")
    clock[0] += timedelta(seconds=6)
    clock[1] += 6
    collect(client, sid, clock, beaconId="b")
    assert preview(client, sid)["observations"] == []
    create(client, sid)
    collect(client, sid, clock, beaconId="b")
    assert [x["beaconId"] for x in preview(client, sid)["observations"]] == ["b"]


def test_mac_payload_compatible_and_naive_timestamp_rejected(client, clock):
    sid = create(client)
    collect(client, sid, clock, macAddress="AA:BB:CC:DD:EE:01")
    response = client.post("/api/v3/beacon/ingest", json=dict(
        sessionId=sid, deviceId="x", beaconId="b", rssi=-60, source="REAL_BLE",
        timestamp="2026-10-23T12:00:00"))
    assert response.status_code == 422
