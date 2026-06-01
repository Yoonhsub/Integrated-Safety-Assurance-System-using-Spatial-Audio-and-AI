from __future__ import annotations

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
import os

from services.public_data.public_data_client import (
    BusArrivalsService,
    BusLocationService,
    BusRouteService,
)

from app.schemas.v3 import (
    AgentConverseRequest,
    AgentConverseResponse,
    AgentIntent,
    AgentTtsRequest,
    BeaconDecision,
    CueType,
    FallbackSource,
    GuidanceState,
    TtsMode,
    V3Cue,
)
from app.services import cheongju_route_catalog
from app.services.v3_gemini_service import (
    generate_optional_reply,
    synthesize_tts_wav,
    generate_dynamic_response,
)
from app.services.v3_guidance_store import v3_guidance_store

def _is_live_mode() -> bool:
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")

router = APIRouter()

_DESTINATION_ALIASES: tuple[tuple[str, str], ...] = (
    ("사창사거리", "사창사거리"),
    ("사창 사거리", "사창사거리"),
    ("사직사거리", "사창사거리"),
    ("충북대학교 병원", "충북대병원"),
    ("충북대학교병원", "충북대병원"),
    ("충북대병원", "충북대병원"),
    ("충대병원", "충북대병원"),
    ("청주고속버스터미널", "청주고속버스터미널"),
    ("청주 고속버스터미널", "청주고속버스터미널"),
    ("청주터미널", "청주고속버스터미널"),
    ("고속버스터미널", "청주고속버스터미널"),
    ("터미널", "청주고속버스터미널"),
)


@router.post("/tts", response_class=Response)
def tts(payload: AgentTtsRequest) -> Response:
    audio = synthesize_tts_wav(text=payload.text.strip())
    if audio is None:
        raise HTTPException(
            status_code=503,
            detail={
                "error": {
                    "code": "GEMINI_TTS_UNAVAILABLE",
                    "message": "Gemini TTS audio could not be generated.",
                    "detail": {},
                }
            },
        )
    return Response(
        content=audio,
        media_type="audio/wav",
        headers={"X-Gemini-TTS-Voice": "Sulafat"},
    )


@router.post("/converse", response_model=AgentConverseResponse)
def converse(payload: AgentConverseRequest) -> AgentConverseResponse:
    session = v3_guidance_store.get(payload.sessionId, wake_word=payload.wakeWord)
    utterance = payload.utterance.strip()
    wake_word = session.wake_word.strip()

    intent = _detect_intent(utterance, wake_word)
    message = "요청을 이해하지 못했어. 버튼으로 다시 선택해줘."
    tts_mode = TtsMode.LOCAL_TTS
    cue = V3Cue(type=CueType.NONE, ttsMode=TtsMode.NONE)
    used_gemini = False
    fallback_source = FallbackSource.MOCK

    if intent == AgentIntent.WAKE_ONLY:
        message = "네, 말씀하세요."
    elif intent in {AgentIntent.FIND_ROUTE, AgentIntent.CHANGE_DESTINATION, AgentIntent.CORRECT_DESTINATION}:
        destination = _extract_destination(utterance) or session.selected_destination or "사창사거리"
        resolved = cheongju_route_catalog.resolve_or_mock(destination, live=_is_live_mode())
        if resolved is None:
            resolved = cheongju_route_catalog.resolve_or_mock("사창사거리", live=_is_live_mode())
        session.selected_destination = resolved.destination
        session.selected_route_no = resolved.routeNo
        session.selected_route_id = resolved.routeId
        session.selected_stop_id = resolved.stopId
        session.selected_stop_name = resolved.stopName
        session.target_bus_id = None
        session.last_decision = None
        session.nearest_beacon = None
        session.target_bus = None
        session.state = GuidanceState.ROUTE_RECOMMENDED
        
        if _is_live_mode():
            try:
                stops = BusRouteService().get_route_stops("33010", session.selected_route_id)
                context_data = {"route_nodes": [n.nodeNm for n in stops.nodes[:10]] + ["..."]}
                dynamic_msg = generate_dynamic_response(
                    intent=intent, utterance=utterance, wake_word=wake_word, context_data=context_data
                )
                message = dynamic_msg or f"{destination} 방향은 {session.selected_stop_name}에서 {session.selected_route_no}번을 타면 돼."
                used_gemini = bool(dynamic_msg)
                if used_gemini:
                    fallback_source = FallbackSource.PUBLIC_API
                    tts_mode = TtsMode.GEMINI_OPTIONAL
            except Exception:
                message = f"{destination} 방향은 {session.selected_stop_name}에서 {session.selected_route_no}번을 타면 돼."
        else:
            message = f"{destination} 방향은 {session.selected_stop_name}에서 {session.selected_route_no}번을 타면 돼."

    elif intent == AgentIntent.QUERY_ARRIVAL:
        route_no = session.selected_route_no or "502"
        stop_name = session.selected_stop_name or "사창사거리 정류장"
        stop_id = session.selected_stop_id or "CJU285000003"
        route_id = session.selected_route_id or "CJU252000288"
        
        if _is_live_mode():
            try:
                arrivals_res = BusArrivalsService().get_arrivals(stop_id)
                route_arrivals = [a for a in arrivals_res.arrivals if a.routeId == route_id]
                context_data = {
                    "stop_name": stop_name,
                    "route_no": route_no,
                    "arrivals": [a.model_dump(mode="json") for a in route_arrivals]
                }
                dynamic_msg = generate_dynamic_response(
                    intent=intent, utterance=utterance, wake_word=wake_word, context_data=context_data
                )
                message = dynamic_msg or f"{stop_name} 기준 {route_no}번 도착 정보를 가져오지 못했어."
                used_gemini = bool(dynamic_msg)
                if used_gemini:
                    fallback_source = FallbackSource.PUBLIC_API
                    tts_mode = TtsMode.GEMINI_OPTIONAL
            except Exception:
                message = f"실시간 API 조회를 실패했어. {stop_name} 기준 {route_no}번 정보를 가져오지 못했어."
        else:
            message = f"{stop_name} 기준 {route_no}번 첫 번째 버스는 mock 기준 약 6분 뒤 도착 예정이야."

    elif intent == AgentIntent.SELECT_ARRIVAL:
        session.target_bus_id = session.target_bus_id or _default_target_bus_id(session.selected_route_no)
        session.state = GuidanceState.WAITING_FOR_BUS
        message = "6분 뒤 오는 버스로 안내할게. 정류장에 도착하면 대기 범위 감지를 시작할게."

    elif intent == AgentIntent.ASK_CAN_BOARD_CURRENT_BUS:
        if _is_live_mode():
            route_id = session.selected_route_id or "CJU252000288"
            stop_id = session.selected_stop_id or "CJU285000003"
            try:
                locations_res = BusLocationService().get_locations("33010", route_id)
                buses_at_stop = [l for l in locations_res.locations if l.nodeId == stop_id]
                context_data = {
                    "beacon_status": session.last_decision or "NO_BEACON",
                    "live_buses_at_current_stop": [b.model_dump(mode="json") for b in buses_at_stop]
                }
                dynamic_msg = generate_dynamic_response(
                    intent=intent, utterance=utterance, wake_word=wake_word, context_data=context_data
                )
                message = dynamic_msg or "아직 타야 할 버스가 오지 않은 것 같아."
                used_gemini = bool(dynamic_msg)
                if used_gemini:
                    fallback_source = FallbackSource.PUBLIC_API
                    tts_mode = TtsMode.GEMINI_OPTIONAL
            except Exception:
                message = "버스 위치 조회를 실패했어. 비프음이 가까워질 때까지 기다려."
        else:
            tts_mode = TtsMode.SAFETY_LOCAL
            if session.last_decision == BeaconDecision.TARGET_BUS_NEAR:
                message = "응, 지금 가까이 온 버스가 타야 할 버스야. 조심해서 탑승해."
                cue = V3Cue(
                    type=CueType.TARGET_BUS_NEAR,
                    ttsMode=TtsMode.LOCAL_TTS,
                    shouldVibrate=True,
                    shouldBeep=True,
                    message="타야 할 버스가 가까이 왔어.",
                )
            elif session.last_decision == BeaconDecision.WRONG_BUS_NEAR:
                message = "아니야. 지금 가까운 버스는 타야 할 버스가 아니야. 기다려."
                cue = V3Cue(
                    type=CueType.WRONG_BUS_NEAR,
                    ttsMode=TtsMode.SAFETY_LOCAL,
                    shouldVibrate=True,
                    shouldBeep=True,
                    message="잘못된 버스가 가까이 왔어.",
                )
                tts_mode = TtsMode.SAFETY_LOCAL
            else:
                message = "아직 타야 할 버스라고 확인되지 않았어. 비프음이 가까워질 때까지 기다려."
                
    elif intent == AgentIntent.REPORT_MISSED_BUS:
        session.state = GuidanceState.WAITING_FOR_BUS
        session.target_bus_id = _next_target_bus_id(session.selected_route_no, session.target_bus_id)
        session.last_decision = None
        session.nearest_beacon = None
        session.target_bus = None
        message = "괜찮아. 다음 버스를 다시 안내할게."
    elif _contains_wake_word(utterance, wake_word):
        gemini_reply = generate_optional_reply(utterance=utterance, wake_word=wake_word)
        if gemini_reply:
            message = gemini_reply
            tts_mode = TtsMode.GEMINI_OPTIONAL
            used_gemini = True
            fallback_source = FallbackSource.GEMINI
    session.touch()

    return AgentConverseResponse(
        sessionId=session.session_id,
        intent=intent,
        state=session.state,
        message=message,
        ttsMode=tts_mode,
        cue=cue,
        usedGemini=used_gemini,
        fallbackSource=fallback_source,
    )


def _detect_intent(utterance: str, wake_word: str) -> AgentIntent:
    text = utterance.strip()
    compact = _compact(text)
    compact_wake_word = _compact(wake_word)
    if compact in {compact_wake_word, f"{compact_wake_word}야", f"{compact_wake_word}아"}:
        return AgentIntent.WAKE_ONLY
    if "못 탔" in text or "못탔" in compact or "놓쳤" in text:
        return AgentIntent.REPORT_MISSED_BUS
    if "타도" in text or "타도돼" in compact or "앞에 온 버스" in text:
        return AgentIntent.ASK_CAN_BOARD_CURRENT_BUS
    if "아니라" in text:
        return AgentIntent.CORRECT_DESTINATION
    if "바꿔" in text or "변경" in text:
        return AgentIntent.CHANGE_DESTINATION
    if "언제" in text or "몇 분" in text or "몇분" in compact:
        return AgentIntent.QUERY_ARRIVAL
    if "안내해" in text or "오는 걸로" in text or "오는걸로" in compact:
        return AgentIntent.SELECT_ARRIVAL
    if "몇 번" in text or "몇번" in compact or "가야" in text or "타야" in text:
        return AgentIntent.FIND_ROUTE
    return AgentIntent.UNKNOWN


def _contains_wake_word(utterance: str, wake_word: str) -> bool:
    return _compact(wake_word) in _compact(utterance)


def _compact(text: str) -> str:
    return "".join(character for character in text if character.isalnum())


def _extract_destination(utterance: str) -> str | None:
    compact = utterance.replace(" ", "")
    # For correction utterances such as "사직사거리가 아니라 사창사거리야",
    # prefer the destination after "아니라" instead of the misheard phrase before it.
    if "아니라" in utterance:
        return _extract_destination(utterance.split("아니라", 1)[1])
    for alias, canonical in _DESTINATION_ALIASES:
        if alias.replace(" ", "") in compact:
            return canonical
    return None


def _default_target_bus_id(route_no: str | None) -> str:
    if route_no == "823":
        return "BUS_823"
    return "BUS_2"


def _next_target_bus_id(route_no: str | None, current_bus_id: str | None) -> str:
    if route_no == "823":
        return "BUS_823_NEXT"
    if current_bus_id == "BUS_2":
        return "BUS_502_NEXT"
    return "BUS_502_NEXT"
