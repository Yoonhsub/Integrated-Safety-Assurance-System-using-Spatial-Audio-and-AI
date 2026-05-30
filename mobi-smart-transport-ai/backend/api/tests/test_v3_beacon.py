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


def _session_with_route(sid: str = "demo-session-001", route_no: str = "502") -> None:
    client.post("/guidance/session", json={"sessionId": sid})
    client.post("/guidance/start", json={
        "sessionId": sid,
        "selectedStopId": "mock-stop-001",
        "selectedStopName": "충북대중문 정류장",
        "selectedRouteNo": route_no,
        "targetBusId": "BUS_2",
        "targetArrivalMinutes": 6,
    })
    client.post("/mock/geofence", json={"sessionId": sid, "mockStatus": "ARRIVED_AT_STOP"})


def test_wrong_bus_near_when_bus1_near_bus2_mid():
    _session_with_route()
    res = client.post("/mock/beacons", json={
        "sessionId": "demo-session-001",
        "beacons": [
            {"busId": "BUS_1", "routeNo": "511", "distanceLevel": "near", "rssi": -45, "relativePosition": "front"},
            {"busId": "BUS_2", "routeNo": "502", "distanceLevel": "mid", "rssi": -63, "relativePosition": "rear"},
        ],
    })
    assert res.status_code == 200
    body = res.json()
    assert body["decision"] == "WRONG_BUS_NEAR"
    assert body["ttsMode"] == "SAFETY_LOCAL"
    assert body["cue"]["type"] == "WRONG_BUS_NEAR"


def test_target_bus_near():
    _session_with_route()
    res = client.post("/mock/beacons", json={
        "sessionId": "demo-session-001",
        "beacons": [
            {"busId": "BUS_2", "routeNo": "502", "distanceLevel": "near", "rssi": -50, "relativePosition": "front"},
        ],
    })
    assert res.status_code == 200
    body = res.json()
    assert body["decision"] == "TARGET_BUS_NEAR"
    assert body["cue"]["type"] == "TARGET_BUS_NEAR"


def test_target_bus_mid():
    _session_with_route()
    res = client.post("/mock/beacons", json={
        "sessionId": "demo-session-001",
        "beacons": [
            {"busId": "BUS_2", "routeNo": "502", "distanceLevel": "mid", "rssi": -63, "relativePosition": "rear"},
        ],
    })
    assert res.status_code == 200
    assert res.json()["decision"] == "TARGET_BUS_MID"


def test_no_beacon_empty():
    _session_with_route()
    res = client.post("/mock/beacons", json={
        "sessionId": "demo-session-001",
        "beacons": [],
    })
    assert res.status_code == 200
    assert res.json()["decision"] == "NO_BEACON"


def test_rssi_tiebreak_near_wins():
    """두 near beacon 중 RSSI가 더 강한(-45 > -60) 것이 nearest로 선택된다."""
    _session_with_route()
    res = client.post("/mock/beacons", json={
        "sessionId": "demo-session-001",
        "beacons": [
            {"busId": "BUS_STRONG", "routeNo": "511", "distanceLevel": "near", "rssi": -45, "relativePosition": "front"},
            {"busId": "BUS_WEAK",   "routeNo": "511", "distanceLevel": "near", "rssi": -60, "relativePosition": "side"},
            {"busId": "BUS_2",      "routeNo": "502", "distanceLevel": "mid",  "rssi": -63, "relativePosition": "rear"},
        ],
    })
    assert res.status_code == 200
    body = res.json()
    assert body["decision"] == "WRONG_BUS_NEAR"
    state = client.get("/guidance/state?sessionId=demo-session-001").json()
    assert state["nearestBeaconId"] == "BUS_STRONG"


def test_session_last_decision_updated():
    _session_with_route()
    client.post("/mock/beacons", json={
        "sessionId": "demo-session-001",
        "beacons": [
            {"busId": "BUS_1", "routeNo": "511", "distanceLevel": "near", "rssi": -45, "relativePosition": "front"},
            {"busId": "BUS_2", "routeNo": "502", "distanceLevel": "mid", "rssi": -63, "relativePosition": "rear"},
        ],
    })
    state = client.get("/guidance/state?sessionId=demo-session-001").json()
    assert state["lastDecision"] == "WRONG_BUS_NEAR"
    assert state["nearestBeaconId"] == "BUS_1"
    assert state["nearestRouteNo"] == "511"


def test_ask_can_board_wrong_bus_near():
    _session_with_route()
    client.post("/mock/beacons", json={
        "sessionId": "demo-session-001",
        "beacons": [
            {"busId": "BUS_1", "routeNo": "511", "distanceLevel": "near", "rssi": -45, "relativePosition": "front"},
            {"busId": "BUS_2", "routeNo": "502", "distanceLevel": "mid", "rssi": -63, "relativePosition": "rear"},
        ],
    })
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 지금 앞에 온 버스 타도 돼?",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["intent"] == "ASK_CAN_BOARD_CURRENT_BUS"
    assert "아니요" in body["message"]
