from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services import guidance_session_store as store

client = TestClient(app)


@pytest.fixture(autouse=True)
def clear_store():
    store.clear_all()
    yield
    store.clear_all()


def _session(sid: str = "demo-session-001") -> None:
    client.post("/guidance/session", json={"sessionId": sid})


def _advance_to_route_selected(sid: str = "demo-session-001") -> None:
    _session(sid)
    client.post("/guidance/start", json={
        "sessionId": sid,
        "selectedStopId": "mock-stop-001",
        "selectedStopName": "충북대중문 정류장",
        "selectedRouteNo": "502",
        "targetBusId": "BUS_2",
        "targetArrivalMinutes": 6,
    })


def test_no_warning_before_arrived():
    _advance_to_route_selected()
    res = client.post("/mock/geofence", json={
        "sessionId": "demo-session-001",
        "mockStatus": "LEFT_WAITING_AREA",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["geofenceStatus"] == "SAFE"
    assert body["shouldSpeak"] is False
    assert body["shouldVibrate"] is False


def test_arrived_sets_geofence_armed():
    _advance_to_route_selected()
    res = client.post("/mock/geofence", json={
        "sessionId": "demo-session-001",
        "mockStatus": "ARRIVED_AT_STOP",
    })
    assert res.status_code == 200
    assert res.json()["geofenceStatus"] == "SAFE"
    state = client.get("/guidance/state?sessionId=demo-session-001").json()
    assert state["geofenceArmed"] is True
    assert state["hasArrivedAtStop"] is True
    assert state["guidanceState"] == "WAITING_FOR_BUS"


def test_warning_after_arrived():
    _advance_to_route_selected()
    client.post("/mock/geofence", json={
        "sessionId": "demo-session-001",
        "mockStatus": "ARRIVED_AT_STOP",
    })
    res = client.post("/mock/geofence", json={
        "sessionId": "demo-session-001",
        "mockStatus": "LEFT_WAITING_AREA",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["geofenceStatus"] == "WARNING"
    assert body["shouldSpeak"] is True
    assert body["shouldVibrate"] is True
    assert body["ttsMode"] == "SAFETY_LOCAL"
    assert body["cue"]["type"] == "GEOFENCE_WARNING"


def test_danger_zone():
    _advance_to_route_selected()
    res = client.post("/mock/geofence", json={
        "sessionId": "demo-session-001",
        "mockStatus": "DANGER_ZONE",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["geofenceStatus"] == "DANGER"
    assert body["shouldVibrate"] is True
    assert body["cue"]["type"] == "DANGER"


def test_returned_to_stop_safe():
    _advance_to_route_selected()
    client.post("/mock/geofence", json={"sessionId": "demo-session-001", "mockStatus": "ARRIVED_AT_STOP"})
    res = client.post("/mock/geofence", json={
        "sessionId": "demo-session-001",
        "mockStatus": "RETURNED_TO_STOP",
    })
    assert res.status_code == 200
    assert res.json()["geofenceStatus"] == "SAFE"
    state = client.get("/guidance/state?sessionId=demo-session-001").json()
    assert state["geofenceArmed"] is True


def test_mock_geofence_unknown_session_404():
    res = client.post("/mock/geofence", json={
        "sessionId": "ghost",
        "mockStatus": "ARRIVED_AT_STOP",
    })
    assert res.status_code == 404


def test_mock_geofence_invalid_status_400():
    _session()
    res = client.post("/mock/geofence", json={
        "sessionId": "demo-session-001",
        "mockStatus": "INVALID_STATUS",
    })
    assert res.status_code == 400
