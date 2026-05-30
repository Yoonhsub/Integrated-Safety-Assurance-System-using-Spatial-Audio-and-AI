from __future__ import annotations

import re

from app.schemas.guidance import GuidanceState
from app.services import (
    gemini_client,
    guidance_session_store as store,
    guidance_state_service as state_svc,
    route_recommendation_service as rec_svc,
    wake_word_service,
)

_DESTINATION_KEYWORDS = ["사창사거리", "충북대병원", "청주고속버스터미널", "사창", "충대병원", "터미널"]


def _rule_intent(utterance: str) -> tuple[str, dict]:
    u = utterance
    # SET_WAKE_WORD
    if "호출어" in u and ("바꿔" in u or "변경" in u or "로 해" in u):
        return "SET_WAKE_WORD", {}
    # REPORT_MISSED_BUS (must be before CONFIRM_BOARDED)
    if re.search(r"못 탔|못탔|놓쳤|못 탑승", u):
        return "REPORT_MISSED_BUS", {}
    # CONFIRM_BOARDED
    if re.search(r"(탔어|탑승했어|탔다|탑승했다)", u):
        return "CONFIRM_BOARDED", {}
    # ASK_CAN_BOARD_CURRENT_BUS
    if re.search(r"(타도 돼|탑승해도 돼|지금 타도|이 버스 타)", u):
        return "ASK_CAN_BOARD_CURRENT_BUS", {}
    # CHANGE_DESTINATION
    if re.search(r"(바꿔|변경|다시|목적지 바)", u) and "호출어" not in u:
        # Need destination clue
        for dest in _DESTINATION_KEYWORDS:
            if dest in u:
                return "CHANGE_DESTINATION", {"destination": dest}
        return "CHANGE_DESTINATION", {}
    # CORRECT_DESTINATION
    if re.search(r"(아니라|아닌데|틀렸|잘못)", u):
        for dest in _DESTINATION_KEYWORDS:
            if dest in u:
                return "CORRECT_DESTINATION", {"destination": dest}
        return "CORRECT_DESTINATION", {}
    # GET_BUS_ARRIVAL (must be before SELECT_ARRIVAL — "언제 와" takes priority)
    if re.search(r"(언제 와|얼마나 남|몇 분|도착|올 때)", u):
        return "GET_BUS_ARRIVAL", {}
    # SELECT_ARRIVAL
    if re.search(r"(6분|첫 번째|그걸로|그거로|그 버스로)", u):
        return "SELECT_ARRIVAL", {"index": 0}
    if re.search(r"(25분|두 번째|다음 버스로)", u):
        return "SELECT_ARRIVAL", {"index": 1}
    # FIND_ROUTE
    for dest in _DESTINATION_KEYWORDS:
        if dest in u and re.search(r"(가야|가고|몇 번|어느|노선|타야)", u):
            return "FIND_ROUTE", {"destination": dest}
    # ASK_CURRENT_STATUS
    if re.search(r"(지금 상태|현재 상태|어디)", u):
        return "ASK_CURRENT_STATUS", {}
    return "UNKNOWN", {}


def _can_board_answer(session) -> str:
    decision = session.lastDecision if session else None
    if decision == "WRONG_BUS_NEAR":
        return "아니요, 현재 앞에 있는 버스는 탑승하실 버스가 아닙니다. 잠시 대기해 주세요."
    if decision in {"TARGET_BUS_NEAR", "TARGET_BUS_MID"}:
        return "네, 탑승하실 버스가 가까이 왔습니다. 탑승하세요."
    return "아직 버스 위치를 확인할 수 없습니다. 잠시만 기다려 주세요."


def process(session_id: str, utterance: str, lat: float | None, lng: float | None) -> dict:
    session = store.get_session(session_id)
    if not session:
        session = state_svc.create_or_get_session(session_id)

    wake_word = session.wakeWord or "자비스"
    recognized, normalized = wake_word_service.detect(utterance, wake_word)

    if recognized and not normalized:
        return {
            "recognizedWakeWord": True,
            "intent": "WAKE_ONLY",
            "slots": {},
            "guidanceState": session.guidanceState.value,
            "message": "네, 말씀하세요.",
            "shouldSpeak": True,
            "ttsMode": "GEMINI_TTS",
            "cue": None,
            "debug": {
                "rawUtterance": utterance,
                "normalizedUtterance": normalized,
                "agentSource": "RULE",
                "lastApi": None,
            },
        }

    text_to_parse = normalized if recognized else utterance
    agent_source = "RULE_FALLBACK"

    gemini_result = gemini_client.extract_intent_and_slots(text_to_parse)
    if gemini_result:
        intent = gemini_result.get("intent", "UNKNOWN")
        slots = gemini_result.get("slots", {})
        agent_source = "GEMINI"
    else:
        intent, slots = _rule_intent(text_to_parse)

    message, cue, last_api = _handle_intent(intent, slots, session, lat, lng)

    updated_session = store.get_session(session_id)
    if updated_session:
        updated_session = updated_session.model_copy(update={
            "lastAiIntent": intent,
            "lastMessage": message,
            "lastApi": last_api,
        })
        store.save_session(updated_session)

    current_state = (updated_session or session).guidanceState.value

    return {
        "recognizedWakeWord": recognized,
        "intent": intent,
        "slots": slots,
        "guidanceState": current_state,
        "message": message,
        "shouldSpeak": True,
        "ttsMode": "GEMINI_TTS",
        "cue": cue,
        "debug": {
            "rawUtterance": utterance,
            "normalizedUtterance": text_to_parse,
            "agentSource": agent_source,
            "lastApi": last_api,
        },
    }


def _handle_intent(intent: str, slots: dict, session, lat, lng) -> tuple[str, dict | None, str | None]:
    session_id = session.sessionId

    if intent == "FIND_ROUTE":
        dest = slots.get("destination") or _extract_dest_from_session(session)
        if not dest:
            return "목적지를 말씀해 주세요.", None, None
        try:
            from app.schemas.route_recommendation import RouteRecommendRequest
            entry = rec_svc.recommend_route(dest)
            updated = session.model_copy(update={
                "destination": dest,
                "selectedStopId": entry["recommendedStopId"],
                "selectedStopName": entry["recommendedStopName"],
                "selectedRouteNo": entry["routeNo"],
                "selectedRouteId": entry["routeId"],
                "guidanceState": GuidanceState.ROUTE_RECOMMENDED,
            })
            store.save_session(updated)
            return entry["message"], None, "/bus/route-recommend"
        except Exception:
            return f"'{dest}' 방향 버스 정보를 찾을 수 없습니다.", None, "/bus/route-recommend"

    if intent == "GET_BUS_ARRIVAL":
        stop_id = session.selectedStopId or "mock-stop-001"
        route_no = session.selectedRouteNo or "502"
        result = rec_svc.get_arrivals(stop_id, route_no)
        return result.message, None, "/bus/arrivals"

    if intent == "SELECT_ARRIVAL":
        stop_id = session.selectedStopId or "mock-stop-001"
        route_no = session.selectedRouteNo or "502"
        result = rec_svc.get_arrivals(stop_id, route_no)
        idx = slots.get("index", 0)
        if result.arrivals and idx < len(result.arrivals):
            chosen = result.arrivals[idx]
            updated = session.model_copy(update={
                "targetBusId": chosen.busId,
                "targetArrivalMinutes": chosen.arrivalMinutes,
                "guidanceState": GuidanceState.ROUTE_SELECTED,
            })
            store.save_session(updated)
            return (
                f"알겠습니다. {chosen.arrivalMinutes}분 뒤 오는 {route_no}번 버스 ({chosen.busId})로 안내하겠습니다.",
                None,
                "/bus/arrivals",
            )
        return "선택한 버스 정보를 찾을 수 없습니다.", None, "/bus/arrivals"

    if intent == "ASK_CAN_BOARD_CURRENT_BUS":
        return _can_board_answer(session), None, None

    if intent in {"CHANGE_DESTINATION", "CORRECT_DESTINATION"}:
        dest = slots.get("destination")
        if dest:
            try:
                entry = rec_svc.recommend_route(dest)
                updated = session.model_copy(update={
                    "destination": dest,
                    "selectedStopId": entry["recommendedStopId"],
                    "selectedStopName": entry["recommendedStopName"],
                    "selectedRouteNo": entry["routeNo"],
                    "guidanceState": GuidanceState.ROUTE_RECOMMENDED,
                })
                store.save_session(updated)
                return f"목적지를 '{dest}'으로 변경했습니다. " + entry["message"], None, "/bus/route-recommend"
            except Exception:
                pass
        return "변경할 목적지를 다시 말씀해 주세요.", None, None

    if intent == "CONFIRM_BOARDED":
        updated = session.model_copy(update={"guidanceState": GuidanceState.BOARDED})
        store.save_session(updated)
        return "탑승을 확인했습니다. 목적지 근처에서 다시 안내해드리겠습니다.", None, None

    if intent == "REPORT_MISSED_BUS":
        stop_id = session.selectedStopId or "mock-stop-001"
        route_no = session.selectedRouteNo or "502"
        result = rec_svc.get_arrivals(stop_id, route_no)
        next_arrival = result.arrivals[1] if len(result.arrivals) > 1 else None
        updated = session.model_copy(update={"guidanceState": GuidanceState.WAITING_FOR_BUS})
        store.save_session(updated)
        if next_arrival:
            return (
                f"알겠습니다. 다음 {route_no}번 버스는 약 {next_arrival.arrivalMinutes}분 뒤 도착 예정입니다. "
                "다음 버스로 다시 안내하겠습니다.",
                None,
                "/bus/arrivals",
            )
        return "다음 버스 정보를 가져오는 중입니다. 잠시 기다려 주세요.", None, "/bus/arrivals"

    if intent == "ASK_CURRENT_STATUS":
        state = session.guidanceState.value
        return f"현재 안내 상태는 '{state}'입니다.", None, None

    return "죄송합니다, 말씀을 정확히 이해하지 못했습니다. 다시 말씀해 주세요.", None, None


def _extract_dest_from_session(session) -> str | None:
    return session.destination if session else None
