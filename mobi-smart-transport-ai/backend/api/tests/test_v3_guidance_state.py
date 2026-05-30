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


def test_create_session_default():
    res = client.post("/guidance/session", json={})
    assert res.status_code == 200
    body = res.json()
    assert body["sessionId"] == "demo-session-001"
    assert body["guidanceState"] == "IDLE"
    assert body["wakeWord"] == "자비스"
    assert body["hasArrivedAtStop"] is False
    assert body["geofenceArmed"] is False


def test_create_session_custom():
    res = client.post("/guidance/session", json={
        "sessionId": "test-session-999",
        "userId": "user-test",
        "wakeWord": "헤이클로바",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["sessionId"] == "test-session-999"
    assert body["wakeWord"] == "헤이클로바"


def test_create_session_idempotent():
    client.post("/guidance/session", json={"sessionId": "s1"})
    res = client.post("/guidance/session", json={"sessionId": "s1"})
    assert res.status_code == 200
    assert res.json()["sessionId"] == "s1"


def test_reset_returns_idle():
    client.post("/guidance/session", json={"sessionId": "s2"})
    res = client.post("/guidance/state/reset", json={"sessionId": "s2"})
    assert res.status_code == 200
    assert res.json()["guidanceState"] == "IDLE"


def test_reset_unknown_session_404():
    res = client.post("/guidance/state/reset", json={"sessionId": "no-such-session"})
    assert res.status_code == 404


def test_get_state():
    client.post("/guidance/session", json={"sessionId": "s3"})
    res = client.get("/guidance/state?sessionId=s3")
    assert res.status_code == 200
    assert res.json()["guidanceState"] == "IDLE"


def test_get_state_unknown_404():
    res = client.get("/guidance/state?sessionId=ghost")
    assert res.status_code == 404


def test_transition_idle_to_destination_set():
    client.post("/guidance/session", json={"sessionId": "tx1"})
    res = client.post("/guidance/transition", json={"sessionId": "tx1", "targetState": "DESTINATION_SET"})
    assert res.status_code == 200
    assert res.json()["guidanceState"] == "DESTINATION_SET"


def test_transition_full_happy_path():
    sid = "happy"
    client.post("/guidance/session", json={"sessionId": sid})
    steps = [
        "DESTINATION_SET", "ROUTE_RECOMMENDED", "ROUTE_SELECTED",
        "NAVIGATING_TO_STOP", "ARRIVED_AT_STOP", "WAITING_FOR_BUS",
        "BUS_APPROACHING", "BOARDING_CONFIRMATION", "BOARDED",
    ]
    for state in steps:
        res = client.post("/guidance/transition", json={"sessionId": sid, "targetState": state})
        assert res.status_code == 200, f"전이 실패: {state}"
        assert res.json()["guidanceState"] == state


def test_transition_missed_bus_replan_loop():
    sid = "missed"
    client.post("/guidance/session", json={"sessionId": sid})
    for state in [
        "DESTINATION_SET", "ROUTE_RECOMMENDED", "ROUTE_SELECTED",
        "NAVIGATING_TO_STOP", "ARRIVED_AT_STOP", "WAITING_FOR_BUS",
        "BUS_APPROACHING", "BOARDING_CONFIRMATION", "MISSED_BUS",
        "REPLAN_NEXT_BUS", "WAITING_FOR_BUS",
    ]:
        res = client.post("/guidance/transition", json={"sessionId": sid, "targetState": state})
        assert res.status_code == 200


def test_invalid_transition_idle_to_boarded():
    client.post("/guidance/session", json={"sessionId": "inv1"})
    res = client.post("/guidance/transition", json={"sessionId": "inv1", "targetState": "BOARDED"})
    assert res.status_code == 400


def test_invalid_transition_idle_to_arrived():
    client.post("/guidance/session", json={"sessionId": "inv2"})
    res = client.post("/guidance/transition", json={"sessionId": "inv2", "targetState": "ARRIVED_AT_STOP"})
    assert res.status_code == 400


def test_invalid_transition_waiting_to_boarded():
    sid = "inv3"
    client.post("/guidance/session", json={"sessionId": sid})
    for state in ["DESTINATION_SET", "ROUTE_RECOMMENDED", "ROUTE_SELECTED",
                  "NAVIGATING_TO_STOP", "ARRIVED_AT_STOP", "WAITING_FOR_BUS"]:
        client.post("/guidance/transition", json={"sessionId": sid, "targetState": state})
    res = client.post("/guidance/transition", json={"sessionId": sid, "targetState": "BOARDED"})
    assert res.status_code == 400


def test_geofence_not_armed_before_arrived():
    sid = "geo1"
    client.post("/guidance/session", json={"sessionId": sid})
    for state in ["DESTINATION_SET", "ROUTE_RECOMMENDED", "ROUTE_SELECTED", "NAVIGATING_TO_STOP"]:
        client.post("/guidance/transition", json={"sessionId": sid, "targetState": state})
    res = client.get(f"/guidance/state?sessionId={sid}")
    body = res.json()
    assert body["geofenceArmed"] is False
    assert body["hasArrivedAtStop"] is False


def test_geofence_armed_after_arrived():
    sid = "geo2"
    client.post("/guidance/session", json={"sessionId": sid})
    for state in ["DESTINATION_SET", "ROUTE_RECOMMENDED", "ROUTE_SELECTED",
                  "NAVIGATING_TO_STOP", "ARRIVED_AT_STOP"]:
        client.post("/guidance/transition", json={"sessionId": sid, "targetState": state})
    res = client.get(f"/guidance/state?sessionId={sid}")
    body = res.json()
    assert body["geofenceArmed"] is True
    assert body["hasArrivedAtStop"] is True


def test_start_guidance_saves_data():
    sid = "start1"
    client.post("/guidance/session", json={"sessionId": sid})
    res = client.post("/guidance/start", json={
        "sessionId": sid,
        "selectedStopId": "mock-stop-001",
        "selectedStopName": "충북대중문 정류장",
        "selectedRouteNo": "502",
        "targetBusId": "BUS_2",
        "targetArrivalMinutes": 6,
    })
    assert res.status_code == 200
    body = res.json()
    assert body["guidanceState"] == "ROUTE_SELECTED"
    assert body["selectedStopId"] == "mock-stop-001"
    assert body["selectedStopName"] == "충북대중문 정류장"
    assert body["selectedRouteNo"] == "502"
    assert body["targetBusId"] == "BUS_2"
    assert body["targetArrivalMinutes"] == 6
