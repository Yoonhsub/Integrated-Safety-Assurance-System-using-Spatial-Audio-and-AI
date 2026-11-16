import pytest

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


def test_saved_route_hides_legacy_default_first_bus_without_changing_storage():
    from app.services.v3_guidance_store import V3SessionRecord

    old_message = "지금 운행 중인 버스가 없습니다. 가장 빠른 버스는 05시30분에 운행할 예정이에요."
    legacy_status = {"operatingNow": False, "reason": "OUTSIDE_SERVICE_WINDOW", "message": old_message,
                     "nextServiceTime": "05:30", "nextServiceLabel": "05시30분", "scheduleSource": "DEFAULT_FALLBACK"}
    plan = {"destinationName": "청주대학교·뉴시스", "boardingInstruction": "711번을 타세요. " + old_message,
            "serviceStatus": legacy_status, "segments": [{"routeNo": "711", "arrivalUnknown": True,
                "serviceStatus": legacy_status, "boardStop": {"stopName": "충북대학교입구"}}]}
    record = V3SessionRecord(session_id="offline-saved-plan", selected_route_no="711", selected_plan=plan)

    response = record.to_response().selectedPlan
    assert response["serviceStatus"]["nextServiceTime"] is None
    assert response["segments"][0]["serviceStatus"]["nextServiceLabel"] is None
    assert "05시30분" not in response["boardingInstruction"]
    followup = v3_agent._contextual_followup_reply(session=record, utterance="무슨 경로?")
    assert "첫차 시각은 확인되지 않았어요" in followup and "05시30분" not in followup
    assert record.to_response(for_storage=True).selectedPlan == plan
    assert record.selected_plan["serviceStatus"]["nextServiceTime"] == "05:30"


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


def test_agent_route_message_includes_boarding_and_alighting_steps() -> None:
    response = _say(
        "s-hospital-guidance",
        "자비스, 충북대병원으로 안내해줘",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert response.status_code == 200
    body = response.json()
    message = body["message"]
    assert body["routePlan"]["status"] == "RESOLVED"
    assert "사창사거리 정류장" in message
    assert "823번" in message
    assert "충북대학교병원 정류장" in message
    assert message.index("사창사거리 정류장") < message.index("823번")
    assert message.index("823번") < message.index("충북대학교병원 정류장")


def test_agent_converse_resolves_cheongju_university_if_going_phrase() -> None:
    response = _say(
        "s-cheongju-univ",
        "자비스, 청주대에 가려면 어떻게 해요?",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["intent"] == "FIND_ROUTE"
    assert body["routePlan"]["status"] == "RESOLVED"
    assert body["routePlan"]["destination"]["topCandidate"]["name"] == "청주대학교"
    assert body["routePlan"]["recommendedPlan"]["segments"][0]["routeNo"] == "502"
    assert "혹시" not in body["message"]
    assert "약국" not in body["message"]
    assert "충북대학교" not in body["message"]


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
    assert first_body["message"] == "혹시 상당산성 맞을까요?"

    pending = client.get("/guidance/state", params={"sessionId": "s-confirm"}).json()
    assert pending["pendingResolutionStatus"] == "NEEDS_CONFIRMATION"
    assert pending["pendingQuestion"] == "혹시 상당산성 맞을까요?"

    second = _say("s-confirm", "응 맞아")

    assert second.status_code == 200
    second_body = second.json()
    assert second_body["routePlan"]["status"] == "RESOLVED"
    assert second_body["routePlan"]["recommendedPlan"]["segments"][0]["routeNo"] == "862"

    state = client.get("/guidance/state", params={"sessionId": "s-confirm"}).json()
    assert state["selectedDestination"] == "상당산성"
    assert state["selectedRouteNo"] == "862"
    assert state["pendingResolutionStatus"] is None


@pytest.fixture
def pending_numbered_route(monkeypatch):
    from app.schemas.v3 import DestinationCandidate, DestinationResolveResponse, RoutePlanResponse

    monkeypatch.setenv("CHEONGJU_ROUTE_PLAN_ROUTE_NOS", "auto")
    monkeypatch.setenv("PUBLIC_DATA_USE_MOCK", "true")
    monkeypatch.setattr(v3_agent, "classify_intent", lambda **kw: {
        "intent": "FIND_ROUTE", "destination": "상단산성" if "상단산성" in kw["utterance"] else "사창사거리",
    })
    calls = []
    statuses = ["NEEDS_CONFIRMATION"]
    candidates = [
        DestinationCandidate(name=name, type="STOP", confidence=0.9)
        for name in ("상당산성", "청주고속버스터미널")
    ]

    def plan(**kwargs):
        calls.append(kwargs)
        status = statuses.pop(0) if statuses else "NO_ROUTE"
        heard = kwargs["heard_text"]
        return RoutePlanResponse(status=status, heardText=heard, fallbackSource="PUBLIC_API",
            question="목적지를 확인해 주세요.",
            destination=DestinationResolveResponse(
                status=status if status != "NO_ROUTE" else "RESOLVED", heardText=heard,
                normalizedText=heard, topCandidate=candidates[0], candidates=candidates,
                fallbackSource="PUBLIC_API",
            ))

    monkeypatch.setattr(v3_agent, "_plan_route", plan)
    return calls, statuses


@pytest.mark.parametrize(("utterance", "model_place", "search_place"), [
    ("충북대학교 가고싶어", "충북대", "충북대학교"),
    ("청주대학교", "청주대", "청주대학교"),
    ("충북대학교입구역", "충북대학교", "충북대학교입구역"),
])
def test_live_chat_and_voice_text_keeps_the_spoken_place(
    pending_numbered_route, monkeypatch, utterance, model_place, search_place
):
    calls, _ = pending_numbered_route
    monkeypatch.setattr(v3_agent, "classify_intent", lambda **_: {
        "intent": "FIND_ROUTE", "destination": model_place,
    })
    response = _say("campus-query", utterance, mode="live",
                    originLat=36.64, originLng=127.46)
    assert response.status_code == 200
    assert response.json()["routePlan"]["heardText"] == search_place
    assert calls[0]["heard_text"] == search_place
    assert calls[0]["origin_lat"] == 36.64
    assert calls[0]["origin_lng"] == 127.46


@pytest.mark.parametrize("initial_status,answer", [
    ("NEEDS_CONFIRMATION", "응 맞아"),
    ("NEEDS_CHOICE", "첫 번째"),
])
def test_numbered_route_filter_survives_destination_answer(pending_numbered_route, initial_status, answer):
    calls, statuses = pending_numbered_route
    statuses[:] = [initial_status, "NEEDS_CONFIRMATION"]
    sid = "numbered-pending"
    first = _say(sid, "611번 버스로 상단산성 가는 경로 알려줘", mode="live",
                 originLat=36.6359, originLng=127.4596)
    assert first.json()["routePlan"]["status"] == initial_status
    assert v3_guidance_store.get(sid).pending_route_no == "611"

    wrong_mode = _say(sid, answer, mode="mock")
    assert wrong_mode.status_code == 409 and len(calls) == 1
    assert _say(sid, answer, mode=None).json()["routePlan"]["status"] == "NEEDS_CONFIRMATION"
    assert v3_guidance_store.get(sid).pending_route_no == "611"
    final = _say(sid, "응 맞아", mode=None).json()
    assert final["routePlan"]["status"] == "NO_ROUTE"
    assert final["routePlan"]["recommendedPlan"] is None
    assert [(c["route_no"], c["mode"], c["origin_lat"]) for c in calls] == [("611", "live", 36.6359)] * 3
    assert calls[-1]["heard_text"] == "상당산성"
    assert v3_guidance_store.get(sid).pending_route_no is None


@pytest.mark.parametrize("cancel_first", [False, True])
def test_new_destination_does_not_inherit_pending_route_number(pending_numbered_route, cancel_first):
    calls, _ = pending_numbered_route
    sid = "numbered-pending-replaced"
    first = _say(sid, "611번 버스로 상단산성 가는 경로 알려줘", mode="live")
    assert first.json()["routePlan"]["status"] == "NEEDS_CONFIRMATION"
    assert calls[0]["route_no"] == "611"
    if cancel_first:
        assert _say(sid, "아니", mode="live").status_code == 200
        assert v3_guidance_store.get(sid).pending_route_no is None

    new = _say(sid, "사창사거리 가는 경로 알려줘", mode="live",
               originLat=36.6359, originLng=127.4596)
    assert new.json()["routePlan"]["status"] == "NO_ROUTE"
    assert len(calls) == 2 and calls[-1].get("route_no") is None
    assert v3_guidance_store.get(sid).pending_route_no is None


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
    assert body["routePlan"]["status"] in {"RESOLVED", "NO_ROUTE", "ALREADY_NEAR_DESTINATION"}
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
    assert second.json()["message"] == "알겠어요. 목적지를 다시 말씀해 주세요."
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


def test_agent_converse_without_origin_does_not_use_destination_stop_as_boarding() -> None:
    response = _say("s-no-origin-hospital", "자비스, 충북대병원 어떻게 가?")

    assert response.status_code == 200
    body = response.json()
    assert body["routePlan"]["status"] == "NOT_FOUND"
    assert body["routePlan"]["recommendedPlan"] is None
    assert "위치 권한" in body["message"]
    assert "충북대학교병원 정류장에서 823번" not in body["message"]
    state = client.get("/guidance/state", params={"sessionId": "s-no-origin-hospital"}).json()
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


def test_agent_route_plan_uses_verified_deterministic_reply_without_waiting_for_gemini(monkeypatch) -> None:
    captured = {}

    def fake_reply(**kwargs):
        captured.update(kwargs)
        return "계산된 RoutePlan 기준으로 862번을 타면 돼."

    monkeypatch.setattr(v3_agent, "generate_route_plan_reply", fake_reply, raising=False)

    response = _say(
        "s-gemini",
        "자비스, 상당산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["usedGemini"] is False
    assert body["ttsMode"] == "SAFETY_LOCAL"
    assert "862번" in body["message"]
    assert captured == {}


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


def test_agent_contextual_route_followup_uses_selected_route_plan() -> None:
    first = _say(
        "s-context-route",
        "자비스, 상당산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )
    assert first.status_code == 200
    assert first.json()["routePlan"]["status"] == "RESOLVED"

    followup = _say("s-context-route", "무슨 경로?")

    assert followup.status_code == 200
    body = followup.json()
    assert body["intent"] == "UNKNOWN"
    assert body["state"] == "ROUTE_RECOMMENDED"
    assert "862번" in body["message"]
    assert "사창사거리" in body["message"]
    assert "먼저 목적지" not in body["message"]


@pytest.mark.parametrize("utterance", [
    "충북대병원", "청주대", "청주대 가는 버스", "충북대병원 노선 검색",
    "충북대병원 길 찾아줘", "청주대 경로 찾아줘", "충북대병원 가는 길",
])
def test_agent_routes_normal_destination_requests_with_nlu_unavailable(monkeypatch, utterance) -> None:
    from app.services import v3_gemini_service

    monkeypatch.setattr(v3_gemini_service, "_generate", lambda **kwargs: None)
    response = _say(
        "s-nlu-unavailable", utterance,
        originLat=36.6359, originLng=127.4596,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["intent"] == "FIND_ROUTE"
    assert body["routePlan"]["status"] == "RESOLVED"
    assert body["routePlan"]["recommendedPlan"] is not None
    assert body["usedGemini"] is False


@pytest.mark.parametrize("utterance", ["충북대병원", "청주대 가는 버스"])
def test_live_route_intent_without_nlu_still_requires_origin(monkeypatch, utterance) -> None:
    from app.services import v3_gemini_service

    monkeypatch.setattr(v3_gemini_service, "_generate", lambda **kwargs: None)
    response = _say("s-live-nlu-unavailable", utterance, mode="live")
    assert response.status_code == 200
    body = response.json()
    assert body["intent"] == "FIND_ROUTE"
    assert body["routePlan"]["recommendedPlan"] is None
    assert "위치 권한" in body["message"]


def test_unrecognized_chatter_without_nlu_gives_actionable_example(monkeypatch) -> None:
    from app.services import v3_gemini_service

    monkeypatch.setattr(v3_gemini_service, "_generate", lambda **kwargs: None)
    response = _say("s-unknown-nlu-unavailable", "오늘 날씨 좋다")
    assert response.status_code == 200
    body = response.json()
    assert body["intent"] == "UNKNOWN"
    assert body["routePlan"] is None
    assert "충북대병원 어떻게 가?" in body["message"]

@pytest.mark.parametrize('correction', ['충북대학교 정문', '충북대학교 정문이요'])
def test_gate_correction_does_not_repeat_hospital_confirmation(correction):
    first = _say('s-gate-correction', '충북대학교 가는 경로 알려줘',
                 originLat=36.6262, originLng=127.4312)
    assert first.status_code == 200
    assert '병원' in first.json()['message']
    assert first.json()['usedGemini'] is False
    second = _say('s-gate-correction', correction)
    assert second.status_code == 200
    body = second.json()
    assert '병원' not in body['message']
    assert '정문' in body['message']
    assert body['usedGemini'] is False
    assert body['routePlan']['status'] == 'NOT_FOUND'
    state = v3_guidance_store.get('s-gate-correction')
    assert state.pending_resolution_status is None

def test_provider_failure_does_not_trigger_gemini_place_guess(monkeypatch):
    from app.schemas.v3 import RoutePlanResponse, RoutePlanStatus, DestinationResolveResponse, DestinationResolveStatus
    failed=RoutePlanResponse(status=RoutePlanStatus.NOT_FOUND,heardText='청주대학교',fallbackSource=FallbackSource.ERROR,
        destination=DestinationResolveResponse(status=DestinationResolveStatus.NOT_FOUND,heardText='청주대학교',normalizedText='청주대학교',fallbackSource=FallbackSource.ERROR,
            question='정류장 정보 조회에 실패했어요. 현재 경로를 확인할 수 없습니다.'))
    monkeypatch.setattr(v3_agent,'_plan_route',lambda **kw:failed)
    monkeypatch.setattr(v3_agent,'_infer_destination_confirmation',lambda **kw:pytest.fail('provider failure must not trigger another Gemini/place lookup'))
    result=_say('offline-provider-error','청주대학교 가는 경로 알려줘',mode='live',originLat=36.63443041,originLng=127.454072)
    assert result.status_code==200
    assert result.json()['fallbackSource']=='ERROR'
    assert result.json()['routePlan']['recommendedPlan'] is None
    assert result.json()['usedGemini'] is False
    generation = next(event for event in result.json()['trace'] if event['type'] == 'GEMINI_REPLY_GENERATION')
    assert generation['status'] == 'SKIPPED'
    assert '실패' in generation['summary']
    assert '검증된 경로' not in generation['summary']
