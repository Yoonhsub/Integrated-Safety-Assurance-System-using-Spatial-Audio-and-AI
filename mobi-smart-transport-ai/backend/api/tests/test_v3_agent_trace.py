import json
import time

from fastapi.testclient import TestClient

from app.main import app
from app.schemas.v3 import AgentTraceEvent
from app.services.v3_agent_trace import AgentTraceRecorder
from app.services.v3_guidance_store import v3_guidance_store


client = TestClient(app)


def setup_function() -> None:
    v3_guidance_store.clear()


def _say(session_id: str, utterance: str, **extra):
    payload = {
        "sessionId": session_id,
        "wakeWord": "모비",
        "utterance": utterance,
        "mode": "mock",
    }
    payload.update(extra)
    return client.post("/agent/converse", json=payload)


def _trace_types(body: dict) -> list[str]:
    return [event["type"] for event in body["trace"]]


def test_agent_trace_event_schema_accepts_user_facing_event() -> None:
    event = AgentTraceEvent(
        id="trace-1",
        step=1,
        type="NORMALIZE_UTTERANCE",
        title="사용자 발화 정리 완료",
        status="DONE",
        summary="호출어를 제거했어.",
        safePayload={"cleanedUtterance": "상당산성 가고 싶어"},
    )

    assert event.status == "DONE"
    assert event.safePayload["cleanedUtterance"] == "상당산성 가고 싶어"


def test_trace_recorder_redacts_secrets_urls_and_precise_coordinates() -> None:
    recorder = AgentTraceRecorder(trace_id="trace-redaction")
    sanitized = recorder.sanitize_payload(
        {
            "apiKey": "secret-value",
            "Authorization": "Bearer hidden-value",
            "nested": {"serviceKey": "another-secret"},
            "url": "https://api.example.com/path?serviceKey=secret",
            "latitude": 36.63594787,
            "longitude": 127.4596675,
            "tokenLike": "A" * 48,
        }
    )

    assert sanitized["apiKey"] == "[REDACTED]"
    assert sanitized["Authorization"] == "[REDACTED]"
    assert sanitized["nested"]["serviceKey"] == "[REDACTED]"
    assert sanitized["url"] == "[URL_REDACTED]"
    assert sanitized["latitude"] == 36.6359
    assert sanitized["longitude"] == 127.4597
    assert sanitized["tokenLike"] == "[REDACTED]"


def test_trace_recorder_measures_duration_and_finishes_status() -> None:
    recorder = AgentTraceRecorder(trace_id="trace-duration")
    event_id = recorder.start("NORMALIZE_UTTERANCE", "입력 정리")
    time.sleep(0.002)
    event = recorder.done(event_id, "입력 정리를 마쳤어.")

    assert event.status == "DONE"
    assert event.durationMs is not None
    assert event.durationMs >= 1


def test_agent_converse_includes_grounded_route_trace_in_order() -> None:
    response = _say(
        "trace-fortress",
        "모비야 상당산성 가고 싶어",
        originLat=36.6359,
        originLng=127.4596,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["traceId"].startswith("trace-")
    types = _trace_types(body)
    expected = [
        "NORMALIZE_UTTERANCE",
        "CLASSIFY_INTENT",
        "DESTINATION_RESOLVE",
        "KAKAO_PLACE_SEARCH",
        "NEARBY_STOP_SEARCH",
        "NEAR_DESTINATION_GUARD",
        "ODSAY_ROUTE_SEARCH",
        "TAGO_ROUTE_VERIFY",
        "TAGO_ARRIVAL_LOOKUP",
        "SERVICE_STATUS_CHECK",
        "GEMINI_REPLY_GENERATION",
        "SAFETY_FILTER",
        "FINAL_RESPONSE",
    ]
    indexes = [types.index(event_type) for event_type in expected]
    assert indexes == sorted(indexes)
    assert body["routePlan"]["recommendedPlan"]["segments"][0]["routeNo"] == "862"


def test_pending_terminal_choice_trace_records_selected_candidate() -> None:
    first = _say(
        "trace-terminal",
        "터미널 어떻게 가?",
        originLat=36.6359,
        originLng=127.4596,
    )
    second = _say("trace-terminal", "고속버스 터미널")

    assert first.json()["routePlan"]["status"] == "NEEDS_CHOICE"
    selected = [
        event
        for event in second.json()["trace"]
        if event["type"] == "PENDING_CHOICE_MATCH" and event["status"] == "DONE"
    ]
    assert selected
    assert selected[0]["safePayload"]["selectedCandidate"] == "청주고속버스터미널"
    assert second.json()["routePlan"]["heardText"] == "청주고속버스터미널"


def test_new_destination_trace_records_route_replacement() -> None:
    _say(
        "trace-replace",
        "사창사거리 어떻게 가?",
        originLat=36.6262,
        originLng=127.4312,
    )
    response = _say(
        "trace-replace",
        "충북대병원 어떻게 가?",
        originLat=36.6359,
        originLng=127.4596,
    )

    replacement = next(
        event for event in response.json()["trace"] if event["type"] == "SESSION_ROUTE_REPLACE"
    )
    assert replacement["safePayload"] == {
        "previousDestination": "사창사거리",
        "newDestination": "충북대학교병원",
    }
    assert response.json()["routePlan"]["recommendedPlan"]["destinationName"] == "충북대학교병원"


def test_near_destination_trace_skips_bus_route_details() -> None:
    response = _say(
        "trace-near",
        "사창사거리 어떻게 가?",
        originLat=36.63594787,
        originLng=127.4596675,
    )

    assert response.status_code == 200
    body = response.json()
    guard = next(event for event in body["trace"] if event["type"] == "NEAR_DESTINATION_GUARD")
    route_verify = next(event for event in body["trace"] if event["type"] == "TAGO_ROUTE_VERIFY")
    assert body["routePlan"]["status"] == "ALREADY_NEAR_DESTINATION"
    assert guard["safePayload"]["alreadyNear"] is True
    assert route_verify["status"] == "SKIPPED"


def test_trace_payload_never_exposes_secret_like_values() -> None:
    recorder = AgentTraceRecorder(trace_id="trace-no-secret")
    recorder.record(
        "FINAL_RESPONSE",
        "최종 안내",
        "검증을 마쳤어.",
        safe_payload={
            "GEMINI_API_KEY": "dont-show-this",
            "PUBLIC_DATA_API_KEY": "dont-show-this-too",
            "key": "dont-show-this-either",
        },
    )

    dumped = json.dumps([event.model_dump(mode="json") for event in recorder.to_list()])
    assert "dont-show" not in dumped
    assert dumped.count("[REDACTED]") == 3
