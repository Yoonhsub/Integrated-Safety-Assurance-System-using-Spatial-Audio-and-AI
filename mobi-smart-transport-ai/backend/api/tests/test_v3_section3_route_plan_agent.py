from fastapi.testclient import TestClient

from app.api.routes import v3_agent
from app.main import app
from app.schemas.v3 import FallbackSource, V3BusArrival, V3BusArrivalsResponse
from app.services.v3_guidance_store import v3_guidance_store

client = TestClient(app)


def setup_function() -> None:
    v3_guidance_store.clear()


def _say(session_id: str, utterance: str, **extra):
    payload = {
        "sessionId": session_id,
        "wakeWord": "자비스",
        "utterance": utterance,
        "mode": "mock",
    }
    payload.update(extra)
    return client.post("/agent/converse", json=payload)


def test_agent_converse_returns_structured_route_plan_for_arbitrary_place() -> None:
    response = _say(
        "s-route",
        "자비스, 상당산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["intent"] == "FIND_ROUTE"
    assert body["state"] == "ROUTE_RECOMMENDED"
    assert body["routePlan"]["status"] == "RESOLVED"
    assert body["routePlan"]["recommendedPlan"]["segments"][0]["routeNo"] == "862"
    assert "건너편" not in body["message"]

    state = client.get("/guidance/state", params={"sessionId": "s-route"}).json()
    assert state["selectedDestination"] == "상당산성"
    assert state["selectedRouteNo"] == "862"
    assert state["selectedStopName"] == "사창사거리 정류장"
    assert state["pendingResolutionStatus"] is None
    assert state["selectedPlan"]["segments"][0]["routeId"] == "mock-route-862-to-fortress"
    assert state["nearbyBoardingStops"]
    assert state["nearbyAlightingStops"]


def test_agent_converse_confirmation_followup_uses_pending_route_plan_context() -> None:
    first = _say(
        "s-confirm",
        "자비스, 상단산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert first.status_code == 200
    first_body = first.json()
    assert first_body["routePlan"]["status"] == "NEEDS_CONFIRMATION"
    assert first_body["message"] == "혹시 상당산성이 맞아?"

    pending = client.get("/guidance/state", params={"sessionId": "s-confirm"}).json()
    assert pending["pendingResolutionStatus"] == "NEEDS_CONFIRMATION"
    assert pending["pendingQuestion"] == "혹시 상당산성이 맞아?"

    second = _say("s-confirm", "응 맞아")

    assert second.status_code == 200
    second_body = second.json()
    assert second_body["routePlan"]["status"] == "RESOLVED"
    assert second_body["routePlan"]["recommendedPlan"]["segments"][0]["routeNo"] == "862"

    state = client.get("/guidance/state", params={"sessionId": "s-confirm"}).json()
    assert state["selectedDestination"] == "상당산성"
    assert state["selectedRouteNo"] == "862"
    assert state["pendingResolutionStatus"] is None


def test_agent_converse_choice_followup_reuses_saved_origin() -> None:
    first = _say(
        "s-choice",
        "자비스, 터미널 가고 싶어",
        originLat=36.6262,
        originLng=127.4312,
    )

    assert first.status_code == 200
    assert first.json()["routePlan"]["status"] == "NEEDS_CHOICE"

    second = _say("s-choice", "첫 번째")
    assert second.status_code == 200
    body = second.json()
    assert body["routePlan"]["status"] in {"RESOLVED", "NO_ROUTE"}
    assert body["routePlan"]["heardText"] == "청주고속버스터미널"


def test_agent_converse_negative_confirmation_clears_pending_state() -> None:
    first = _say(
        "s-confirm-no",
        "자비스, 상단산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )
    assert first.json()["routePlan"]["status"] == "NEEDS_CONFIRMATION"

    second = _say("s-confirm-no", "아니")

    assert second.status_code == 200
    assert second.json()["routePlan"] is None
    assert second.json()["message"] == "알겠어. 목적지를 다시 말해줘."
    state = client.get("/guidance/state", params={"sessionId": "s-confirm-no"}).json()
    assert state["pendingResolutionStatus"] is None


def test_agent_converse_without_origin_does_not_invent_route_for_new_destination() -> None:
    response = _say("s-no-origin", "자비스, 상당산성 가고 싶어")

    assert response.status_code == 200
    body = response.json()
    assert body["routePlan"]["status"] == "NOT_FOUND"
    assert body["routePlan"]["recommendedPlan"] is None
    assert "위치 권한" in body["message"]
    state = client.get("/guidance/state", params={"sessionId": "s-no-origin"}).json()
    assert state["selectedDestination"] is None
    assert state["selectedRouteNo"] is None


def test_agent_converse_rejects_unknown_mode() -> None:
    response = client.post(
        "/agent/converse",
        json={
            "sessionId": "s-bad-mode",
            "wakeWord": "자비스",
            "utterance": "자비스, 상당산성 가고 싶어",
            "mode": "preview",
        },
    )

    assert response.status_code == 422


def test_agent_converse_rejects_partial_origin_coordinates() -> None:
    response = client.post(
        "/agent/converse",
        json={
            "sessionId": "s-partial-origin",
            "wakeWord": "자비스",
            "utterance": "자비스, 상당산성 가고 싶어",
            "mode": "mock",
            "originLat": 36.6359,
        },
    )

    assert response.status_code == 422


def test_agent_route_plan_gemini_reply_is_bound_to_computed_json(monkeypatch) -> None:
    captured = {}

    def fake_reply(**kwargs):
        captured.update(kwargs)
        return "계산된 RoutePlan 기준으로 862번을 타면 돼."

    monkeypatch.setattr(v3_agent, "generate_route_plan_reply", fake_reply)

    response = _say(
        "s-gemini",
        "자비스, 상당산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["usedGemini"] is True
    assert body["ttsMode"] == "GEMINI_OPTIONAL"
    assert body["message"] == "계산된 RoutePlan 기준으로 862번을 타면 돼."
    assert captured["route_plan"]["recommendedPlan"]["segments"][0]["routeNo"] == "862"


def test_agent_arrival_refresh_uses_selected_plan_route_and_boarding_stop(monkeypatch) -> None:
    from app.api.routes import v3_bus

    first = _say(
        "s-refresh-arrival",
        "자비스, 상당산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )
    assert first.json()["routePlan"]["status"] == "RESOLVED"

    captured = {}

    def fake_arrivals(stop_id, *, route_no, route_id, live, mode):
        captured.update(
            {
                "stop_id": stop_id,
                "route_no": route_no,
                "route_id": route_id,
                "live": live,
                "mode": mode,
            }
        )
        return V3BusArrivalsResponse(
            stopId=stop_id,
            routeNo=route_no,
            arrivals=[
                V3BusArrival(
                    busId="BUS_REFRESH",
                    routeNo=route_no,
                    routeId=route_id,
                    stopId=stop_id,
                    arrivalMinutes=4,
                )
            ],
            fallbackSource=FallbackSource.MOCK,
        )

    monkeypatch.setattr(v3_bus, "_route_plan_arrivals", fake_arrivals)
    response = _say("s-refresh-arrival", "도착정보 다시 알려줘")

    assert response.status_code == 200
    assert response.json()["intent"] == "QUERY_ARRIVAL"
    assert "862번" in response.json()["message"]
    assert "약 4분" in response.json()["message"]
    assert captured == {
        "stop_id": "mock-stop-001",
        "route_no": "862",
        "route_id": "mock-route-862-to-fortress",
        "live": False,
        "mode": "mock",
    }


def test_agent_arrival_refresh_without_selected_plan_does_not_invent_default_route() -> None:
    response = _say("s-refresh-empty", "도착정보 다시 알려줘")

    assert response.status_code == 200
    body = response.json()
    assert body["intent"] == "QUERY_ARRIVAL"
    assert "먼저 목적지 경로를 선택" in body["message"]
    assert "502" not in body["message"]
