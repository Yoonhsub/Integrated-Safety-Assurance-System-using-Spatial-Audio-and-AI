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


def _make_session(sid: str = "demo-session-001") -> None:
    client.post("/guidance/session", json={"sessionId": sid})


# ── 노선 추천 ──────────────────────────────────────────────
def test_recommend_sachang():
    _make_session()
    res = client.post("/bus/route-recommend", json={
        "sessionId": "demo-session-001",
        "destination": "사창사거리",
        "lat": 36.6282,
        "lng": 127.4562,
    })
    assert res.status_code == 200
    body = res.json()
    assert body["selectedRouteNo"] == "502"
    assert body["selectedStopId"] == "mock-stop-001"
    assert body["guidanceState"] == "ROUTE_RECOMMENDED"


def test_recommend_alias_sachang():
    _make_session()
    res = client.post("/bus/route-recommend", json={
        "sessionId": "demo-session-001",
        "destination": "사창",
    })
    assert res.status_code == 200
    assert res.json()["selectedRouteNo"] == "502"


def test_recommend_chungbuk_hospital():
    _make_session()
    res = client.post("/bus/route-recommend", json={
        "sessionId": "demo-session-001",
        "destination": "충북대병원",
    })
    assert res.status_code == 200
    assert res.json()["selectedRouteNo"] == "105"


def test_recommend_terminal():
    _make_session()
    res = client.post("/bus/route-recommend", json={
        "sessionId": "demo-session-001",
        "destination": "청주고속버스터미널",
    })
    assert res.status_code == 200
    assert res.json()["selectedRouteNo"] == "747"


def test_recommend_unknown_destination_404():
    _make_session()
    res = client.post("/bus/route-recommend", json={
        "sessionId": "demo-session-001",
        "destination": "존재하지않는곳",
    })
    assert res.status_code == 404


def test_recommend_updates_guidance_session():
    _make_session()
    client.post("/bus/route-recommend", json={
        "sessionId": "demo-session-001",
        "destination": "사창사거리",
    })
    state_res = client.get("/guidance/state?sessionId=demo-session-001")
    body = state_res.json()
    assert body["guidanceState"] == "ROUTE_RECOMMENDED"
    assert body["destination"] == "사창사거리"
    assert body["selectedStopId"] == "mock-stop-001"
    assert body["selectedRouteNo"] == "502"


# ── 버스 도착 정보 ─────────────────────────────────────────
def test_arrivals_502_first_bus():
    res = client.get("/bus/arrivals?stopId=mock-stop-001&routeNo=502")
    assert res.status_code == 200
    body = res.json()
    assert body["stopId"] == "mock-stop-001"
    assert body["routeNo"] == "502"
    assert len(body["arrivals"]) >= 1
    assert body["arrivals"][0]["arrivalMinutes"] == 6
    assert body["arrivals"][0]["busId"] == "BUS_2"


def test_arrivals_502_second_bus():
    res = client.get("/bus/arrivals?stopId=mock-stop-001&routeNo=502")
    body = res.json()
    assert len(body["arrivals"]) >= 2
    assert body["arrivals"][1]["arrivalMinutes"] == 25


def test_arrivals_no_fake_congestion():
    res = client.get("/bus/arrivals?stopId=mock-stop-001&routeNo=502")
    body = res.json()
    for arrival in body["arrivals"]:
        assert "congestion" not in arrival
        assert "crowding" not in arrival


def test_arrivals_has_fallback_source():
    res = client.get("/bus/arrivals?stopId=mock-stop-001&routeNo=502")
    body = res.json()
    assert "fallbackSource" in body


def test_arrivals_unknown_route_returns_empty():
    res = client.get("/bus/arrivals?stopId=mock-stop-001&routeNo=999")
    assert res.status_code == 200
    body = res.json()
    assert body["arrivals"] == []
