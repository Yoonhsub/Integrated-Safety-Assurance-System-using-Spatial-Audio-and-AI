from __future__ import annotations

import os
import re
from typing import Callable

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response

from services.public_data.public_data_client import (
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
    RoutePlanResponse,
    RoutePlanStatus,
    TtsMode,
    V3Cue,
)
from app.services import cheongju_route_catalog
from app.services.transit_planner_orchestrator import TransitPlannerOrchestrator
from app.services.destination_candidate_resolver import DestinationCandidateResolver
from app.services.v3_gemini_service import (
    classify_intent,
    generate_dynamic_response,
    generate_optional_reply,
    generate_route_plan_reply,
    synthesize_tts_wav,
)
from app.services.v3_guidance_store import V3SessionRecord, v3_guidance_store


def _is_live_mode() -> bool:
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")


def _resolve_live(mode: str | None) -> bool:
    """요청별 mode가 오면 그것을 우선 적용하고, 없으면 전역 env로 폴백한다."""
    if mode:
        return mode.strip().lower() == "live"
    return _is_live_mode()


router = APIRouter()

_DESTINATION_ALIASES: tuple[tuple[str, str], ...] = (
    ("사창사거리", "사창사거리"),
    ("사창 사거리", "사창사거리"),
    ("사직사거리", "사창사거리"),
    ("충북대학교 병원", "충북대학교병원"),
    ("충북대학교병원", "충북대학교병원"),
    ("충북대병원", "충북대학교병원"),
    ("충대병원", "충북대학교병원"),
    ("청주고속버스터미널", "청주고속버스터미널"),
    ("청주 고속버스터미널", "청주고속버스터미널"),
    ("청주터미널", "청주고속버스터미널"),
    ("고속버스터미널", "청주고속버스터미널"),
    ("터미널", "청주고속버스터미널"),
)

_destination_resolver = DestinationCandidateResolver()


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
    live = _resolve_live(payload.mode)

    # 목적지 후보 확인/선택 질문이 걸린 상태에서는 "응 맞아", "두 번째" 같은 후속 발화를
    # 먼저 소비한다. Flash/Gemini가 이 짧은 답변을 잡담으로 오분류하는 것을 막기 위함이다.
    pending_response = _try_answer_pending_destination(session, payload, live=live)
    if pending_response is not None:
        return pending_response

    keyword_intent = _detect_intent(utterance, wake_word)
    classification = (
        classify_intent(
            utterance=utterance,
            wake_word=wake_word,
            known_destinations=cheongju_route_catalog.DESTINATIONS,
        )
        if keyword_intent == AgentIntent.UNKNOWN
        else None
    )
    intent = keyword_intent
    nlp_destination: str | None = None
    if classification is not None and classification["intent"] != AgentIntent.UNKNOWN.value:
        intent = AgentIntent(classification["intent"])
        nlp_destination = classification["destination"]

    message = "요청을 이해하지 못했어. 버튼으로 다시 선택해줘."
    tts_mode = TtsMode.LOCAL_TTS
    cue = V3Cue(type=CueType.NONE, ttsMode=TtsMode.NONE)
    used_gemini = False
    fallback_source = FallbackSource.MOCK
    route_plan: RoutePlanResponse | None = None

    if intent == AgentIntent.WAKE_ONLY:
        message = "네, 말씀하세요."

    elif intent in {AgentIntent.FIND_ROUTE, AgentIntent.CHANGE_DESTINATION, AgentIntent.CORRECT_DESTINATION}:
        route_plan, message, tts_mode, used_gemini, fallback_source = _handle_route_request(
            session=session,
            payload=payload,
            intent=intent,
            nlp_destination=nlp_destination,
            live=live,
        )

    elif intent == AgentIntent.QUERY_ARRIVAL:
        selected = _selected_arrival_target(session)
        if selected is None:
            message = "먼저 목적지 경로를 선택해줘. 선택한 경로가 있어야 도착정보를 다시 확인할 수 있어."
            fallback_source = FallbackSource.ERROR
        else:
            route_no, route_id, stop_id, stop_name = selected
            try:
                from app.api.routes import v3_bus

                arrivals_res = v3_bus._route_plan_arrivals(
                    stop_id,
                    route_no=route_no,
                    route_id=route_id,
                    live=live,
                    mode=payload.mode,
                )
                route_arrivals = [
                    item
                    for item in arrivals_res.arrivals
                    if item.routeNo == route_no or item.routeId == route_id
                ]
                fallback_source = arrivals_res.fallbackSource
                if route_arrivals:
                    first = min(item.arrivalMinutes for item in route_arrivals)
                    source_label = "실시간" if arrivals_res.fallbackSource == FallbackSource.PUBLIC_API else arrivals_res.fallbackSource.value
                    message = f"{stop_name} 기준 {route_no}번 첫 번째 버스는 {source_label} 기준 약 {first}분 뒤 도착 예정이야."
                else:
                    message = f"{stop_name} 기준 {route_no}번 도착정보는 아직 확인되지 않았어."
            except Exception:
                fallback_source = FallbackSource.ERROR
                message = f"{stop_name} 기준 {route_no}번 도착정보를 가져오지 못했어."

    elif intent == AgentIntent.SELECT_ARRIVAL:
        if not session.selected_route_no:
            message = "먼저 목적지 경로를 선택해줘."
        else:
            session.target_bus_id = _first_plan_arrival_bus_id(session) or session.target_bus_id
            if session.target_bus_id is None and session.last_route_plan is None:
                session.target_bus_id = _default_target_bus_id(session.selected_route_no)
            session.state = GuidanceState.WAITING_FOR_BUS
            message = "선택한 경로로 안내할게. 정류장에 도착하면 대기 범위 감지를 시작할게."

    elif intent == AgentIntent.ASK_CAN_BOARD_CURRENT_BUS:
        if live:
            route_id = session.selected_route_id
            stop_id = session.selected_stop_id
            if not route_id or not stop_id:
                message = "먼저 목적지 경로를 선택해줘."
            else:
                try:
                    locations_res = BusLocationService().get_locations("33010", route_id)
                    buses_at_stop = [l for l in locations_res.locations if l.nodeId == stop_id]
                    context_data = {
                        "beacon_status": session.last_decision or "NO_BEACON",
                        "live_buses_at_current_stop": [b.model_dump(mode="json") for b in buses_at_stop],
                    }
                    dynamic_msg = generate_dynamic_response(
                        intent=intent,
                        utterance=utterance,
                        wake_word=wake_word,
                        context_data=context_data,
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

    else:
        gemini_reply = generate_optional_reply(utterance=utterance, wake_word=wake_word)
        if gemini_reply:
            message = gemini_reply
            tts_mode = TtsMode.GEMINI_OPTIONAL
            used_gemini = True
            fallback_source = FallbackSource.GEMINI
        else:
            message = "지금은 답하기 어려워. 잠시 후에 다시 말해줄래?"

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
        routePlan=route_plan,
    )


def _handle_route_request(
    *,
    session: V3SessionRecord,
    payload: AgentConverseRequest,
    intent: AgentIntent,
    nlp_destination: str | None,
    live: bool,
) -> tuple[RoutePlanResponse | None, str, TtsMode, bool, FallbackSource]:
    destination = _extract_destination(payload.utterance) or nlp_destination or session.selected_destination

    # 위치가 있으면 새 RoutePlan 기반으로 임의 장소/주소/정류장명을 처리한다.
    if payload.originLat is not None and payload.originLng is not None:
        heard_text = nlp_destination or _generic_destination_text(payload.utterance) or destination or payload.utterance
        route_plan = _plan_route(
            heard_text=heard_text,
            origin_lat=payload.originLat,
            origin_lng=payload.originLng,
            live=live,
            mode=payload.mode,
        )
        return _route_plan_response_tuple(
            session=session,
            route_plan=route_plan,
            utterance=payload.utterance,
            wake_word=payload.wakeWord,
            origin_lat=payload.originLat,
            origin_lng=payload.originLng,
        )

    # 기존 테스트/버튼 플로우에 등록된 목적지만 위치 없는 고정 카탈로그 폴백을 유지한다.
    # 임의 장소를 사창사거리로 바꾸면 계산되지 않은 경로를 안내하게 되므로, 새 목적지는
    # RoutePlan의 위치 필요 응답으로 보낸다.
    legacy_destination = _legacy_catalog_key(destination or payload.utterance)
    if legacy_destination is None:
        heard_text = nlp_destination or _generic_destination_text(payload.utterance) or destination or payload.utterance
        route_plan = _plan_route(
            heard_text=heard_text,
            origin_lat=None,
            origin_lng=None,
            live=live,
            mode=payload.mode,
        )
        return _route_plan_response_tuple(
            session=session,
            route_plan=route_plan,
            utterance=payload.utterance,
            wake_word=payload.wakeWord,
            origin_lat=None,
            origin_lng=None,
        )

    resolved = cheongju_route_catalog.resolve_or_mock(legacy_destination, live=live)
    if resolved is None:
        route_plan = _plan_route(
            heard_text=destination or payload.utterance,
            origin_lat=None,
            origin_lng=None,
            live=live,
            mode=payload.mode,
        )
        return _route_plan_response_tuple(
            session=session,
            route_plan=route_plan,
            utterance=payload.utterance,
            wake_word=payload.wakeWord,
            origin_lat=None,
            origin_lng=None,
        )
    _apply_legacy_route(session, resolved.destination, resolved.routeNo, resolved.routeId, resolved.stopId, resolved.stopName)

    used_gemini = False
    tts_mode = TtsMode.LOCAL_TTS
    fallback_source = FallbackSource(resolved.source)
    if live:
        try:
            stops = BusRouteService().get_route_stops("33010", session.selected_route_id)
            context_data = {
                "destination": session.selected_destination,
                "board_stop": session.selected_stop_name,
                "route_no": session.selected_route_no,
                "route_path_sample": [n.nodeNm for n in stops.nodes[:10]] + ["..."],
            }
            dynamic_msg = generate_dynamic_response(
                intent=intent,
                utterance=payload.utterance,
                wake_word=payload.wakeWord,
                context_data=context_data,
            )
            if dynamic_msg:
                used_gemini = True
                tts_mode = TtsMode.GEMINI_OPTIONAL
                return None, dynamic_msg, tts_mode, used_gemini, fallback_source
        except Exception:
            pass
    return (
        None,
        f"{resolved.destination} 방향은 {resolved.stopName}에서 {resolved.routeNo}번을 타면 돼.",
        tts_mode,
        used_gemini,
        fallback_source,
    )


def _route_plan_response_tuple(
    *,
    session: V3SessionRecord,
    route_plan: RoutePlanResponse,
    utterance: str,
    wake_word: str,
    origin_lat: float | None,
    origin_lng: float | None,
) -> tuple[RoutePlanResponse, str, TtsMode, bool, FallbackSource]:
    session.origin_location = (
        {"latitude": origin_lat, "longitude": origin_lng}
        if origin_lat is not None and origin_lng is not None
        else session.origin_location
    )
    if route_plan.status == RoutePlanStatus.RESOLVED and route_plan.recommendedPlan is not None:
        _apply_route_plan(session, route_plan)
        _clear_pending(session)
    elif route_plan.status in {RoutePlanStatus.NEEDS_CONFIRMATION, RoutePlanStatus.NEEDS_CHOICE}:
        _store_pending(session, route_plan, origin_lat=origin_lat, origin_lng=origin_lng)
    else:
        _clear_pending(session)

    dumped = route_plan.model_dump(mode="json")
    gemini_message = generate_route_plan_reply(route_plan=dumped, utterance=utterance, wake_word=wake_word)
    if gemini_message:
        return route_plan, gemini_message, TtsMode.GEMINI_OPTIONAL, True, route_plan.fallbackSource
    return route_plan, _deterministic_route_plan_message(route_plan), TtsMode.LOCAL_TTS, False, route_plan.fallbackSource


def _try_answer_pending_destination(
    session: V3SessionRecord,
    payload: AgentConverseRequest,
    *,
    live: bool,
) -> AgentConverseResponse | None:
    if not session.pending_resolution_status:
        return None

    text = payload.utterance.strip()
    query: str | None = None
    status = session.pending_resolution_status

    if status == RoutePlanStatus.NEEDS_CONFIRMATION.value:
        if _is_negative(text):
            _clear_pending(session)
            session.touch()
            return AgentConverseResponse(
                sessionId=session.session_id,
                intent=AgentIntent.CORRECT_DESTINATION,
                state=session.state,
                message="알겠어. 목적지를 다시 말해줘.",
                ttsMode=TtsMode.LOCAL_TTS,
                cue=V3Cue(),
                usedGemini=False,
                fallbackSource=FallbackSource.MOCK,
                routePlan=None,
            )
        if _is_affirmative(text) and session.pending_top_candidate_name:
            query = session.pending_top_candidate_name
        elif session.pending_top_candidate_name and _compact(session.pending_top_candidate_name) in _compact(text):
            query = session.pending_top_candidate_name

    elif status == RoutePlanStatus.NEEDS_CHOICE.value:
        index = _choice_index(text)
        if index is not None and 0 <= index < len(session.pending_choice_names):
            query = session.pending_choice_names[index]
        else:
            query = _match_choice_name(text, session.pending_choice_names)

    if query is None:
        session.touch()
        return AgentConverseResponse(
            sessionId=session.session_id,
            intent=AgentIntent.FIND_ROUTE,
            state=session.state,
            message=session.pending_question or "어느 목적지인지 한 번만 더 말해줘.",
            ttsMode=TtsMode.LOCAL_TTS,
            cue=V3Cue(),
            usedGemini=False,
            fallbackSource=FallbackSource.MOCK,
            routePlan=None,
        )

    origin_lat = payload.originLat if payload.originLat is not None else session.pending_origin_lat
    origin_lng = payload.originLng if payload.originLng is not None else session.pending_origin_lng
    route_plan = _plan_route(
        heard_text=query,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
        live=live,
        mode=payload.mode,
    )
    route_plan, message, tts_mode, used_gemini, fallback_source = _route_plan_response_tuple(
        session=session,
        route_plan=route_plan,
        utterance=payload.utterance,
        wake_word=payload.wakeWord,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
    )
    session.touch()
    return AgentConverseResponse(
        sessionId=session.session_id,
        intent=AgentIntent.FIND_ROUTE,
        state=session.state,
        message=message,
        ttsMode=tts_mode,
        cue=V3Cue(),
        usedGemini=used_gemini,
        fallbackSource=fallback_source,
        routePlan=route_plan,
    )


def _plan_route(
    *,
    heard_text: str,
    origin_lat: float | None,
    origin_lng: float | None,
    live: bool,
    mode: str | None,
) -> RoutePlanResponse:
    planner = TransitPlannerOrchestrator(
        resolver=_destination_resolver,
        arrival_fetcher=_arrival_fetcher(live=live, mode=mode),
    )
    return planner.plan(
        heard_text=heard_text,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
        live=live,
    )


def _arrival_fetcher(*, live: bool, mode: str | None) -> Callable:
    def fetch(stop_id: str, route_no: str | None, route_id: str | None = None):
        # v3_bus의 arrivals 변환 계약을 그대로 재사용한다. import를 지연시켜 라우터 간 순환 초기화를 피한다.
        from app.api.routes import v3_bus

        return v3_bus._route_plan_arrivals(stop_id, route_no=route_no, route_id=route_id, live=live, mode=mode)

    return fetch


def _apply_route_plan(session: V3SessionRecord, route_plan: RoutePlanResponse) -> None:
    plan = route_plan.recommendedPlan
    if plan is None or not plan.segments:
        return
    segment = plan.segments[0]
    session.selected_destination = plan.destinationName
    session.selected_route_no = segment.routeNo
    session.selected_route_id = segment.routeId
    session.selected_stop_id = segment.boardStop.stopId
    session.selected_stop_name = segment.boardStop.stopName
    session.selected_plan_id = plan.planId
    session.nearby_boarding_stops = [
        item.model_dump(mode="json") for item in route_plan.destination.originStops
    ]
    session.nearby_alighting_stops = [
        item.model_dump(mode="json") for item in route_plan.destination.destinationStops
    ]
    session.recommended_plan = plan.model_dump(mode="json")
    session.alternative_plans = [item.model_dump(mode="json") for item in route_plan.alternatives]
    session.selected_plan = session.recommended_plan
    session.current_leg_index = 0
    session.target_bus_id = None
    session.last_decision = None
    session.nearest_beacon = None
    session.target_bus = None
    session.last_route_plan = route_plan.model_dump(mode="json")
    session.state = GuidanceState.ROUTE_RECOMMENDED


def _apply_legacy_route(
    session: V3SessionRecord,
    destination: str,
    route_no: str,
    route_id: str,
    stop_id: str,
    stop_name: str,
) -> None:
    session.selected_destination = destination
    session.selected_route_no = route_no
    session.selected_route_id = route_id
    session.selected_stop_id = stop_id
    session.selected_stop_name = stop_name
    session.selected_plan_id = None
    session.nearby_boarding_stops = []
    session.nearby_alighting_stops = []
    session.recommended_plan = None
    session.alternative_plans = []
    session.selected_plan = None
    session.current_leg_index = 0
    session.target_bus_id = None
    session.last_decision = None
    session.nearest_beacon = None
    session.target_bus = None
    session.last_route_plan = None
    session.state = GuidanceState.ROUTE_RECOMMENDED
    _clear_pending(session)


def _store_pending(
    session: V3SessionRecord,
    route_plan: RoutePlanResponse,
    *,
    origin_lat: float | None,
    origin_lng: float | None,
) -> None:
    destination = route_plan.destination
    session.pending_question = route_plan.question or destination.question
    session.pending_resolution_status = route_plan.status.value
    session.pending_heard_text = route_plan.heardText
    session.pending_top_candidate_name = destination.topCandidate.name if destination.topCandidate else None
    session.pending_choice_names = [item.name for item in destination.candidates]
    session.pending_origin_lat = origin_lat
    session.pending_origin_lng = origin_lng
    session.nearby_boarding_stops = [
        item.model_dump(mode="json") for item in destination.originStops
    ]
    session.nearby_alighting_stops = [
        item.model_dump(mode="json") for item in destination.destinationStops
    ]
    session.origin_location = (
        {"latitude": origin_lat, "longitude": origin_lng}
        if origin_lat is not None and origin_lng is not None
        else None
    )
    session.last_route_plan = route_plan.model_dump(mode="json")


def _clear_pending(session: V3SessionRecord) -> None:
    session.pending_question = None
    session.pending_resolution_status = None
    session.pending_heard_text = None
    session.pending_top_candidate_name = None
    session.pending_choice_names = []
    session.pending_origin_lat = None
    session.pending_origin_lng = None


def _deterministic_route_plan_message(route_plan: RoutePlanResponse) -> str:
    if route_plan.status != RoutePlanStatus.RESOLVED or route_plan.recommendedPlan is None:
        return route_plan.question or route_plan.destination.question or "목적지를 다시 말해줘."
    plan = route_plan.recommendedPlan
    message = plan.boardingInstruction
    if plan.verificationStatus.value in {"ODSAY_ONLY", "PARTIAL"}:
        message += " 정류장에서는 전광판이나 버스 번호를 한 번 더 확인해줘."
    if not plan.segments[0].directionHint:
        message += " 정류장 방향 정보는 확실히 확인하지 못했어. 정류장 표지판에서 노선 방향을 한 번 더 확인해줘."
    if any("ODsay unavailable" in warning for warning in route_plan.warnings):
        message = f"ODsay 경로탐색은 지금 사용할 수 없어서, 청주 버스 공공데이터 기준으로 경로를 계산했어. {message}"
    if plan.type.value == "ONE_TRANSFER" and len(plan.segments) >= 2:
        second = plan.segments[1]
        message += f" {plan.segments[0].alightStop.stopName}에서 내려 {second.routeNo}번으로 한 번 갈아타면 돼."
    return message


def _first_plan_arrival_bus_id(session: V3SessionRecord) -> str | None:
    plan = (session.last_route_plan or {}).get("recommendedPlan") if isinstance(session.last_route_plan, dict) else None
    if not isinstance(plan, dict):
        return None
    segments = plan.get("segments")
    if not isinstance(segments, list) or not segments:
        return None
    first = segments[0]
    arrivals = first.get("arrivals") if isinstance(first, dict) else None
    if not isinstance(arrivals, list) or not arrivals:
        return None
    bus_id = arrivals[0].get("busId") if isinstance(arrivals[0], dict) else None
    return bus_id if isinstance(bus_id, str) and bus_id else None


def _arrivals_from_last_route_plan(session: V3SessionRecord, *, route_no: str) -> list[dict]:
    plan = (session.last_route_plan or {}).get("recommendedPlan") if isinstance(session.last_route_plan, dict) else None
    if not isinstance(plan, dict):
        return []
    segments = plan.get("segments")
    if not isinstance(segments, list):
        return []
    out: list[dict] = []
    for segment in segments:
        if not isinstance(segment, dict) or segment.get("routeNo") != route_no:
            continue
        arrivals = segment.get("arrivals")
        if isinstance(arrivals, list):
            out.extend(item for item in arrivals if isinstance(item, dict))
    return out


def _selected_arrival_target(session: V3SessionRecord) -> tuple[str, str | None, str, str] | None:
    plan = session.selected_plan or session.recommended_plan
    if isinstance(plan, dict):
        segments = plan.get("segments")
        if isinstance(segments, list) and segments and isinstance(segments[0], dict):
            segment = segments[0]
            board_stop = segment.get("boardStop")
            if isinstance(board_stop, dict):
                route_no = segment.get("routeNo")
                stop_id = board_stop.get("stopId")
                stop_name = board_stop.get("stopName")
                if isinstance(route_no, str) and isinstance(stop_id, str) and isinstance(stop_name, str):
                    route_id = segment.get("routeId")
                    return route_no, route_id if isinstance(route_id, str) else None, stop_id, stop_name
    if session.selected_route_no and session.selected_stop_id and session.selected_stop_name:
        return session.selected_route_no, session.selected_route_id, session.selected_stop_id, session.selected_stop_name
    return None


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
    if "언제" in text or "몇 분" in text or "몇분" in compact or "도착정보" in compact:
        return AgentIntent.QUERY_ARRIVAL
    if "안내해" in text or "오는 걸로" in text or "오는걸로" in compact:
        return AgentIntent.SELECT_ARRIVAL
    if (
        "몇 번" in text
        or "몇번" in compact
        or "가야" in text
        or "가고 싶" in text
        or "가고싶" in compact
        or "가자" in text
        or "가는 법" in text
        or "가는법" in compact
        or "어떻게 가" in text
        or "타야" in text
    ):
        return AgentIntent.FIND_ROUTE
    return AgentIntent.UNKNOWN


def _compact(text: str) -> str:
    return "".join(character for character in text if character.isalnum())


def _extract_destination(utterance: str) -> str | None:
    compact = utterance.replace(" ", "")
    if "아니라" in utterance:
        return _extract_destination(utterance.split("아니라", 1)[1])
    for alias, canonical in _DESTINATION_ALIASES:
        if alias.replace(" ", "") in compact:
            return canonical
    cleaned = _generic_destination_text(utterance)
    return cleaned if cleaned else None


def _generic_destination_text(utterance: str) -> str | None:
    cleaned = utterance.strip()
    cleaned = re.sub(r"^(자비스|모비|mobi|MOBI)[야아,\s]*", "", cleaned)
    cleaned = re.sub(r"^(나|나는|난|저|저는|내가|제가)\s+", "", cleaned).strip()
    if "아니라" in cleaned:
        cleaned = cleaned.split("아니라", 1)[1].strip()
    patterns = [
        r"(으로|로)?\s*가고\s*싶어.*$",
        r"(으로|로)?\s*가야\s*(하는데|돼|해)?.*$",
        r"(으로|로)?\s*가자.*$",
        r"(으로|로)?\s*가는\s*(법|길|버스|노선).*$",
        r"(까지)?\s*어떻게\s*가.*$",
        r"(까지)?\s*몇\s*번.*$",
        r"(까지)?\s*몇번.*$",
        r"(까지)?\s*안내해\s*줘.*$",
        r"(으로|로)?\s*바꿔\s*줘.*$",
    ]
    for pattern in patterns:
        cleaned = re.sub(pattern, "", cleaned).strip()
    cleaned = re.sub(r"(이야|야|입니다|이에요|예요)$", "", cleaned).strip()
    cleaned = re.sub(r"(으로|로|까지|에)$", "", cleaned).strip(" .,?!~…")
    if len(cleaned) < 2 or _compact(cleaned) in {_compact("나"), _compact("저")}:
        return None
    return cleaned


def _legacy_catalog_key(value: str | None) -> str | None:
    if not value:
        return None
    compact = value.replace(" ", "")
    for alias, canonical in _DESTINATION_ALIASES:
        if alias.replace(" ", "") in compact:
            if canonical == "충북대학교병원":
                return "충북대병원"
            return canonical
    return value if cheongju_route_catalog.is_known_destination(value) else None


def _is_affirmative(text: str) -> bool:
    compact = _compact(text)
    return compact in {"응", "어", "맞아", "맞음", "그래", "ㅇㅇ", "네", "예", "맞습니다"} or "맞아" in text or "그거" in text


def _is_negative(text: str) -> bool:
    compact = _compact(text)
    return compact in {"아니", "아니야", "ㄴㄴ", "노", "no"} or "아니" in text


def _choice_index(text: str) -> int | None:
    compact = _compact(text)
    mapping = {
        "1": 0,
        "일번": 0,
        "첫번째": 0,
        "첫째": 0,
        "하나": 0,
        "2": 1,
        "이번": 1,
        "두번째": 1,
        "둘째": 1,
        "둘": 1,
        "3": 2,
        "삼번": 2,
        "세번째": 2,
        "셋째": 2,
        "셋": 2,
    }
    for key, index in mapping.items():
        if key in compact:
            return index
    return None


def _match_choice_name(text: str, names: list[str]) -> str | None:
    compact_text = _compact(text)
    for name in names:
        compact_name = _compact(name)
        if compact_name and (compact_name in compact_text or compact_text in compact_name):
            return name
    return None


def _default_target_bus_id(route_no: str | None) -> str:
    if route_no == "823":
        return "BUS_823"
    if route_no == "862":
        return "BUS_862"
    return "BUS_2"


def _next_target_bus_id(route_no: str | None, current_bus_id: str | None) -> str:
    if route_no == "823":
        return "BUS_823_NEXT"
    if route_no == "862":
        return "BUS_862_NEXT"
    if current_bus_id == "BUS_2":
        return "BUS_502_NEXT"
    return "BUS_502_NEXT"
