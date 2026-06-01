from fastapi.testclient import TestClient

from app.api.routes import v3_agent
from app.main import app
from app.services.v3_guidance_store import v3_guidance_store

client = TestClient(app)


def setup_function() -> None:
    v3_guidance_store.clear()


def test_v3_routes_are_registered() -> None:
    current_routes = {
        (route.path, method)
        for route in app.routes
        for method in getattr(route, "methods", set())
    }

    for path, method in {
        ("/guidance/session", "POST"),
        ("/guidance/state", "GET"),
        ("/guidance/event", "POST"),
        ("/agent/converse", "POST"),
        ("/agent/tts", "POST"),
        ("/bus/route-recommend", "GET"),
        ("/bus/arrivals", "GET"),
        ("/beacon/decision", "GET"),
        ("/mock/geofence", "POST"),
        ("/mock/beacons", "POST"),
        ("/mock/bus-event", "POST"),
    }:
        assert (path, method) in current_routes


def test_v3_session_and_agent_startup_contract() -> None:
    session = client.post("/guidance/session", json={"sessionId": "s1", "wakeWord": "자비스"})
    assert session.status_code == 200
    assert session.json()["state"] == "IDLE"

    wake = client.post("/agent/converse", json={"sessionId": "s1", "utterance": "자비스"})
    assert wake.status_code == 200
    assert wake.json()["intent"] == "WAKE_ONLY"
    assert wake.json()["usedGemini"] is False


def test_custom_agent_name_is_used_as_wake_word() -> None:
    session = client.post("/guidance/session", json={"sessionId": "s1", "wakeWord": "모비"})
    assert session.status_code == 200

    wake = client.post("/agent/converse", json={"sessionId": "s1", "wakeWord": "모비", "utterance": "모비야"})
    assert wake.status_code == 200
    assert wake.json()["intent"] == "WAKE_ONLY"


def test_named_unknown_request_can_use_optional_gemini(monkeypatch) -> None:
    monkeypatch.setattr(
        v3_agent,
        "generate_optional_reply",
        lambda **_: "안녕, 오늘도 이동을 도와줄게.",
    )

    response = client.post(
        "/agent/converse",
        json={"sessionId": "s1", "wakeWord": "모비", "utterance": "모비, 오늘 기분 어때?"},
    )

    assert response.status_code == 200
    assert response.json()["intent"] == "UNKNOWN"
    assert response.json()["usedGemini"] is True
    assert response.json()["fallbackSource"] == "GEMINI"


def test_agent_tts_returns_generated_wav(monkeypatch) -> None:
    monkeypatch.setattr(v3_agent, "synthesize_tts_wav", lambda **_: b"RIFFdemo")

    response = client.post("/agent/tts", json={"text": "안녕"})

    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"
    assert response.headers["x-gemini-tts-voice"] == "Sulafat"
    assert response.content == b"RIFFdemo"


def test_v3_bus_and_mock_endpoints_do_not_require_live_api_keys() -> None:
    recommendation = client.get("/bus/route-recommend", params={"destination": "사창사거리"})
    assert recommendation.status_code == 200
    assert recommendation.json()["recommendations"][0]["routeNo"] == "502"
    assert recommendation.json()["fallbackSource"] == "MOCK"

    arrivals = client.get("/bus/arrivals", params={"stopId": "mock-stop-001", "routeNo": "502"})
    assert arrivals.status_code == 200
    body = arrivals.json()
    assert body["fallbackSource"] == "MOCK"
    assert body["arrivals"][0]["busId"] == "BUS_2"


def test_v3_mock_beacons_updates_last_decision() -> None:
    payload = {
        "sessionId": "s1",
        "targetBusId": "BUS_2",
        "targetRouteNo": "502",
        "beacons": [
            {"busId": "BUS_1", "routeNo": "511", "distanceMeters": 1.5, "rssi": -55},
            {"busId": "BUS_2", "routeNo": "502", "distanceMeters": 7.0, "rssi": -70},
        ],
    }
    response = client.post("/mock/beacons", json=payload)
    assert response.status_code == 200
    assert response.json()["decision"] == "WRONG_BUS_NEAR"

    decision = client.get("/beacon/decision", params={"sessionId": "s1"})
    assert decision.status_code == 200
    assert decision.json()["decision"] == "WRONG_BUS_NEAR"
