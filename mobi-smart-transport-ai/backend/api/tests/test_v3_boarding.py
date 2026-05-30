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


def _full_setup(sid: str = "demo-session-001") -> None:
    client.post("/guidance/session", json={"sessionId": sid})
    client.post("/guidance/start", json={
        "sessionId": sid,
        "selectedStopId": "mock-stop-001",
        "selectedStopName": "충북대중문 정류장",
        "selectedRouteNo": "502",
        "targetBusId": "BUS_2",
        "targetArrivalMinutes": 6,
    })


def test_boarded_true_state():
    _full_setup()
    res = client.post("/guidance/boarding-confirm", json={
        "sessionId": "demo-session-001",
        "boarded": True,
    })
    assert res.status_code == 200
    body = res.json()
    assert body["guidanceState"] == "BOARDED"
    assert "탑승을 확인" in body["message"]


def test_boarded_false_returns_next_bus():
    _full_setup()
    res = client.post("/guidance/boarding-confirm", json={
        "sessionId": "demo-session-001",
        "boarded": False,
    })
    assert res.status_code == 200
    body = res.json()
    assert body["guidanceState"] == "WAITING_FOR_BUS"
    assert body["previousState"] == "MISSED_BUS"
    assert body["nextRouteNo"] == "502"
    assert body["nextArrivalMinutes"] == 25
    assert "25분" in body["message"]
    assert body["fallbackSource"] is not None


def test_report_missed_bus_via_converse():
    _full_setup()
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 나 못 탔어.",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["intent"] == "REPORT_MISSED_BUS"
    assert body["guidanceState"] == "WAITING_FOR_BUS"
    assert "분" in body["message"]


def test_bus_passed_triggers_boarding_confirmation():
    _full_setup()
    client.post("/mock/geofence", json={"sessionId": "demo-session-001", "mockStatus": "ARRIVED_AT_STOP"})
    res = client.post("/mock/bus-event", json={
        "sessionId": "demo-session-001",
        "event": "BUS_PASSED",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["guidanceState"] == "BOARDING_CONFIRMATION"
    assert "탑승하셨나요" in body["message"]


def test_bus_arrived_event():
    _full_setup()
    client.post("/mock/geofence", json={"sessionId": "demo-session-001", "mockStatus": "ARRIVED_AT_STOP"})
    res = client.post("/mock/bus-event", json={
        "sessionId": "demo-session-001",
        "event": "BUS_ARRIVED",
    })
    assert res.status_code == 200
    assert res.json()["guidanceState"] == "BOARDING_CONFIRMATION"


def test_bus_event_invalid_400():
    _full_setup()
    res = client.post("/mock/bus-event", json={
        "sessionId": "demo-session-001",
        "event": "UNKNOWN_EVENT",
    })
    assert res.status_code == 400


def test_fallback_source_in_missed_bus_response():
    _full_setup()
    res = client.post("/guidance/boarding-confirm", json={
        "sessionId": "demo-session-001",
        "boarded": False,
    })
    assert "fallbackSource" in res.json()
