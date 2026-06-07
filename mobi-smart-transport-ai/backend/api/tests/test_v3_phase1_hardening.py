from datetime import time

from fastapi.testclient import TestClient

from app.main import app
from app.services.route_service_status import evaluate_route_service_status
from app.services.v3_guidance_store import v3_guidance_store


client = TestClient(app)


def setup_function() -> None:
    v3_guidance_store.clear()


def _say(session_id: str, utterance: str, *, wake_word: str = "자비스", **extra):
    payload = {
        "sessionId": session_id,
        "wakeWord": wake_word,
        "utterance": utterance,
        "mode": "mock",
    }
    payload.update(extra)
    return client.post("/agent/converse", json=payload)


def test_service_status_after_last_bus_reports_next_first_bus(monkeypatch) -> None:
    monkeypatch.setenv(
        "CHEONGJU_ROUTE_SERVICE_WINDOWS",
        '{"862":{"first":"05:40","last":"22:50"}}',
    )

    status = evaluate_route_service_status(route_no="862", arrivals=[], now=time(23, 49))

    assert status.operatingNow is False
    assert status.reason == "OUTSIDE_SERVICE_WINDOW"
    assert status.nextServiceTime == "05:40"
    assert "지금 운행 중인 버스가 없어" in status.message
    assert "05시40분" in status.message
    assert status.scheduleSource == "ENV_ROUTE_OVERRIDE"


def test_service_status_after_last_bus_keeps_arrival_if_present() -> None:
    status = evaluate_route_service_status(route_no="862", arrivals=[object()], now=time(23, 49))

    assert status.operatingNow is True
    assert status.reason == "ARRIVALS_AVAILABLE"
    assert status.nextServiceTime is None


def test_service_status_daytime_without_arrivals_is_conservative() -> None:
    status = evaluate_route_service_status(route_no="862", arrivals=[], now=time(12, 0))

    assert status.operatingNow is True
    assert status.reason == "ARRIVAL_INFO_UNAVAILABLE_WITHIN_SERVICE_WINDOW"
    assert "운행 중인 버스가 없어" not in status.message
    assert "다시 갱신" in status.message


def test_route_plan_and_arrivals_expose_service_status() -> None:
    route_plan = client.get(
        "/bus/route-plan",
        params={
            "q": "상당산성",
            "originLat": 36.6359,
            "originLng": 127.4596,
            "mode": "mock",
        },
    ).json()
    arrivals = client.get(
        "/bus/arrivals",
        params={"stopId": "mock-stop-001", "routeNo": "862", "mode": "mock"},
    ).json()

    segment = route_plan["recommendedPlan"]["segments"][0]
    assert segment["serviceStatus"]["operatingNow"] is True
    assert route_plan["recommendedPlan"]["serviceStatus"] == segment["serviceStatus"]
    assert arrivals["serviceStatus"]["reason"] == "ARRIVALS_AVAILABLE"


def test_live_route_status_exposes_panel_ready_markers_without_inventing_bus_positions() -> None:
    response = client.get(
        "/bus/live-route-status",
        params={
            "routeNo": "862",
            "routeId": "mock-route-862-to-fortress",
            "boardStopId": "mock-stop-001",
            "alightStopId": "seed-stop-sangdang-fortress",
            "userLat": 36.6359,
            "userLng": 127.4596,
            "mode": "mock",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert {marker["type"] for marker in body["markers"]} == {
        "USER",
        "BOARD_STOP",
        "ALIGHT_STOP",
        "DESTINATION",
    }
    assert body["busPositions"] == []
    assert body["arrivals"][0]["routeNo"] == "862"
    assert body["arrivals"][0]["congestion"] is None
    assert body["serviceStatus"]["reason"] == "ARRIVALS_AVAILABLE"
    assert "현재 버스 위치는 아직 조회되지 않았어." in body["warnings"]


def test_live_route_status_rejects_partial_coordinates() -> None:
    response = client.get(
        "/bus/live-route-status",
        params={
            "routeNo": "862",
            "routeId": "mock-route-862-to-fortress",
            "boardStopId": "mock-stop-001",
            "alightStopId": "seed-stop-sangdang-fortress",
            "userLat": 36.6359,
            "mode": "mock",
        },
    )

    assert response.status_code == 422


def test_route_plan_does_not_force_bus_when_already_near_stop_destination() -> None:
    response = client.get(
        "/bus/route-plan",
        params={
            "q": "사창사거리 어떻게 가?",
            "originLat": 36.63594787,
            "originLng": 127.4596675,
            "mode": "mock",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ALREADY_NEAR_DESTINATION"
    assert body["recommendedPlan"] is None
    assert "따로 버스를 타실 필요는 없어" in body["agentMessage"]


def test_route_plan_does_not_force_bus_when_already_near_place_destination() -> None:
    response = client.get(
        "/bus/route-plan",
        params={
            "q": "충북대병원 어떻게 가?",
            "originLat": 36.6242,
            "originLng": 127.4613,
            "mode": "mock",
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "ALREADY_NEAR_DESTINATION"


def test_route_plan_still_calculates_when_destination_is_far() -> None:
    response = client.get(
        "/bus/route-plan",
        params={
            "q": "상당산성 어떻게 가?",
            "originLat": 36.6359,
            "originLng": 127.4596,
            "mode": "mock",
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "RESOLVED"


def test_mobi_wake_word_is_not_used_as_user_name() -> None:
    response = _say(
        "s-mobi",
        "모비야 사창사거리 어떻게 가?",
        wake_word="모비",
        originLat=36.6262,
        originLng=127.4312,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["routePlan"]["destination"]["topCandidate"]["name"] == "사창사거리"
    assert "모비야" not in body["message"]


def test_new_destination_replaces_selected_route_context() -> None:
    first = _say(
        "s-replace",
        "사창사거리 어떻게 가?",
        originLat=36.6262,
        originLng=127.4312,
    )
    assert first.status_code == 200
    assert client.get("/guidance/state", params={"sessionId": "s-replace"}).json()["selectedDestination"] == "사창사거리"

    second = _say(
        "s-replace",
        "충북대병원 어떻게 가?",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert second.status_code == 200
    body = second.json()
    assert "충북대" in body["message"]
    state = client.get("/guidance/state", params={"sessionId": "s-replace"}).json()
    assert state["selectedDestination"] == "충북대병원"
    assert state["selectedRouteNo"] == "823"


def test_terminal_pending_choice_accepts_high_speed_keyword_and_clears_pending() -> None:
    first = _say(
        "s-terminal-high-speed",
        "터미널 어떻게 가?",
        originLat=36.6359,
        originLng=127.4596,
    )
    assert first.json()["routePlan"]["status"] == "NEEDS_CHOICE"

    second = _say("s-terminal-high-speed", "고속버스 터미널")

    assert second.status_code == 200
    assert second.json()["routePlan"]["heardText"] == "청주고속버스터미널"
    state = client.get("/guidance/state", params={"sessionId": "s-terminal-high-speed"}).json()
    assert state["pendingDestinationCandidates"] == []


def test_terminal_pending_choice_accepts_intercity_keyword() -> None:
    first = _say(
        "s-terminal-intercity",
        "터미널 어떻게 가?",
        originLat=36.6359,
        originLng=127.4596,
    )
    assert first.json()["routePlan"]["status"] == "NEEDS_CHOICE"

    second = _say("s-terminal-intercity", "시외")

    assert second.status_code == 200
    assert second.json()["routePlan"]["heardText"] == "청주시외버스터미널"


def test_terminal_pending_choice_accepts_number() -> None:
    first = _say(
        "s-terminal-number",
        "터미널 어떻게 가?",
        originLat=36.6359,
        originLng=127.4596,
    )
    assert first.json()["routePlan"]["status"] == "NEEDS_CHOICE"

    second = _say("s-terminal-number", "1번")

    assert second.status_code == 200
    assert second.json()["routePlan"]["heardText"] == "청주고속버스터미널"
