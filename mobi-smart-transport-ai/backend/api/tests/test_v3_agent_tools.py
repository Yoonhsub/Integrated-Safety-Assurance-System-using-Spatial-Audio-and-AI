from datetime import datetime

from app.schemas.v3 import AgentIntent, V3BusArrival
from app.services.v3_agent_tools import (
    classify_agent_intent,
    get_service_status_tool,
    match_pending_choice_tool,
    near_destination_guard_tool,
    normalize_user_utterance,
    plan_transit_route_tool,
    resolve_destination_tool,
    sanitize_agent_reply_tool,
    verify_route_tool,
)
from app.services.v3_guidance_store import V3SessionRecord


def test_normalize_user_utterance_removes_mobi_wake_word() -> None:
    normalized = normalize_user_utterance("모비야 사창사거리 어떻게 가?")

    assert normalized.wake_word_detected is True
    assert normalized.cleaned_utterance == "사창사거리 어떻게 가?"
    assert normalized.destination_candidate_text == "사창사거리"


def test_normalize_user_utterance_removes_optional_question_prefix() -> None:
    normalized = normalize_user_utterance("혹시 성화동 925 어떻게 가?")

    assert normalized.destination_candidate_text == "성화동 925"


def test_sanitize_agent_reply_removes_mobi_user_address() -> None:
    assert sanitize_agent_reply_tool("그래, 모비야. 내가 안내해줄게.") == "내가 안내해줄게."


def test_pending_choice_matches_terminal_aliases_and_position() -> None:
    candidates = ["청주시외버스터미널", "청주고속버스터미널"]

    assert match_pending_choice_tool("고속버스 터미널", candidates).candidate == "청주고속버스터미널"
    assert match_pending_choice_tool("시외", candidates).candidate == "청주시외버스터미널"
    assert match_pending_choice_tool("1번", candidates).candidate == "청주시외버스터미널"


def test_classify_agent_intent_prioritizes_new_destination_over_selected_plan() -> None:
    session = V3SessionRecord(
        session_id="tool-new-destination",
        selected_destination="사창사거리",
        selected_plan={"planId": "old-plan"},
    ).to_response()

    result = classify_agent_intent("충북대병원 어떻게 가?", session)

    assert result.intent == AgentIntent.FIND_ROUTE
    assert result.explicit_destination == "충북대병원"


def test_classify_agent_intent_treats_destination_guidance_as_route_request() -> None:
    result = classify_agent_intent("충북대병원으로 안내해줘")

    assert result.intent == AgentIntent.FIND_ROUTE
    assert result.explicit_destination == "충북대병원"


def test_classify_agent_intent_keeps_arriving_bus_guidance_as_selection() -> None:
    result = classify_agent_intent("응, 6분 뒤 오는 걸로 안내해줘.")

    assert result.intent == AgentIntent.SELECT_ARRIVAL


def test_classify_agent_intent_keeps_arrival_followup_contextual() -> None:
    session = V3SessionRecord(
        session_id="tool-arrival-followup",
        selected_destination="사창사거리",
        selected_plan={"planId": "selected-plan"},
    ).to_response()

    result = classify_agent_intent("몇 분 뒤 와?", session)

    assert result.intent == AgentIntent.QUERY_ARRIVAL
    assert result.explicit_destination is None


def test_near_destination_guard_reports_walk_only_for_close_origin() -> None:
    destination = resolve_destination_tool(
        "사창사거리",
        origin_lat=36.63594787,
        origin_lng=127.4596675,
        mode="mock",
    )

    result = near_destination_guard_tool(
        36.63594787,
        127.4596675,
        destination,
    )

    assert result.already_near is True
    assert result.distance_meters is not None
    assert result.distance_meters < 10
    assert "따로 버스를 타실 필요는 없어" in (result.message or "")


def test_service_status_tool_reports_next_bus_after_service_window(monkeypatch) -> None:
    monkeypatch.setenv(
        "CHEONGJU_ROUTE_SERVICE_WINDOWS",
        '{"862":{"first":"05:40","last":"22:50"}}',
    )

    status = get_service_status_tool(
        route_no="862",
        arrivals=[],
        now=datetime(2026, 6, 2, 23, 49),
    )

    assert status.operatingNow is False
    assert status.reason == "OUTSIDE_SERVICE_WINDOW"
    assert status.nextServiceTime == "05:40"
    assert "05시40분" in status.message


def test_service_status_tool_does_not_claim_shutdown_during_daytime() -> None:
    status = get_service_status_tool(
        route_no="862",
        arrivals=[],
        now=datetime(2026, 6, 2, 12, 0),
    )

    assert status.operatingNow is True
    assert status.reason == "ARRIVAL_INFO_UNAVAILABLE_WITHIN_SERVICE_WINDOW"
    assert "운행 중인 버스가 없어" not in status.message


def test_verify_route_tool_removes_arrival_for_another_route() -> None:
    plan = plan_transit_route_tool(
        destination_text="상당산성",
        origin_lat=36.6359,
        origin_lng=127.4596,
        mode="mock",
    )
    segment = plan.recommendedPlan.segments[0]
    segment.arrivals.append(
        V3BusArrival(
            busId="NOT_THIS_ROUTE",
            routeNo="999",
            routeId="mock-route-999",
            stopId=segment.boardStop.stopId,
            arrivalMinutes=1,
        )
    )

    verified = verify_route_tool(plan)

    assert verified.recommendedPlan is not None
    assert {arrival.routeNo for arrival in verified.recommendedPlan.segments[0].arrivals} == {"862"}
