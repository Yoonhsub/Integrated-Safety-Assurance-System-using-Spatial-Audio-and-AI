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


def test_wake_word_only():
    _session()
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["recognizedWakeWord"] is True
    assert body["intent"] == "WAKE_ONLY"
    assert "말씀하세요" in body["message"]


def test_wake_word_with_find_route():
    _session()
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?",
        "lat": 36.6282,
        "lng": 127.4562,
    })
    assert res.status_code == 200
    body = res.json()
    assert body["recognizedWakeWord"] is True
    assert body["intent"] == "FIND_ROUTE"
    assert "502" in body["message"]
    assert body["guidanceState"] == "ROUTE_RECOMMENDED"


def test_get_bus_arrival_intent():
    _session()
    client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 사창사거리 가야 해.",
    })
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 그 버스 언제 와?",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["intent"] == "GET_BUS_ARRIVAL"
    assert "분" in body["message"]


def test_select_arrival_updates_session():
    _session()
    client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 사창사거리 가야 하는데 몇 번 버스 타야 돼?",
    })
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "응, 6분 뒤 오는 걸로 안내해줘.",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["intent"] == "SELECT_ARRIVAL"
    state_res = client.get("/guidance/state?sessionId=demo-session-001")
    state = state_res.json()
    assert state["targetBusId"] == "BUS_2"
    assert state["targetArrivalMinutes"] == 6


def test_change_destination():
    _session()
    client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 사창사거리 가야 해.",
    })
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "아니라 충북대병원으로 바꿔",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["intent"] in {"CHANGE_DESTINATION", "CORRECT_DESTINATION"}


def test_gemini_unavailable_uses_rule_fallback(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    _session()
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 사창사거리 가야 하는데 몇 번 버스 타야 돼?",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["debug"]["agentSource"] in {"RULE_FALLBACK", "RULE"}
    assert body["intent"] == "FIND_ROUTE"


def test_ask_can_board_current_bus_response_structure():
    _session()
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 지금 앞에 온 버스 타도 돼?",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["intent"] == "ASK_CAN_BOARD_CURRENT_BUS"
    assert body["message"] != ""
    assert body["shouldSpeak"] is True


def test_report_missed_bus_resets_to_waiting():
    _session()
    client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 사창사거리 가야 하는데 몇 번 버스 타야 돼?",
    })
    res = client.post("/agent/converse", json={
        "sessionId": "demo-session-001",
        "utterance": "자비스, 나 못 탔어.",
    })
    assert res.status_code == 200
    body = res.json()
    assert body["intent"] == "REPORT_MISSED_BUS"
    assert body["guidanceState"] == "WAITING_FOR_BUS"
    assert "분" in body["message"]
