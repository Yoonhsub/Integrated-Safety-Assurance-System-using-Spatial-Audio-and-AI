from __future__ import annotations

import math
import os
import re
from dataclasses import dataclass
from datetime import datetime
from difflib import SequenceMatcher
from typing import Any, Callable

from app.schemas.v3 import (
    AgentIntent,
    DestinationCandidateType,
    DestinationResolveResponse,
    GuidanceSessionState,
    RoutePlanReadiness,
    RoutePlanResponse,
    RoutePlanStatus,
    V3BusArrival,
    V3BusArrivalsResponse,
)
from app.services.destination_candidate_resolver import DestinationCandidateResolver
from app.services.route_service_status import evaluate_route_service_status
from app.services.transit_planner_orchestrator import TransitPlannerOrchestrator
from app.services.v3_agent_trace import AgentTraceRecorder
from app.services.v3_gemini_service import _without_vision_claims
from services.public_data.public_data_client import BusLocationService, BusRouteService
from services.public_data.public_data_client.schemas import (
    NormalizedBusLocationResponse,
    NormalizedBusRouteStopsResponse,
)


@dataclass(frozen=True)
class NormalizedUtterance:
    original_utterance: str
    cleaned_utterance: str
    wake_word_detected: bool
    destination_candidate_text: str | None


@dataclass(frozen=True)
class AgentIntentResult:
    intent: AgentIntent
    normalized: NormalizedUtterance
    explicit_destination: str | None = None


@dataclass(frozen=True)
class PendingChoiceMatch:
    matched: bool
    candidate: str | None = None
    candidate_index: int | None = None


@dataclass(frozen=True)
class NearDestinationResult:
    already_near: bool
    distance_meters: float | None = None
    message: str | None = None


def normalize_user_utterance(utterance: str, wake_word: str = "모비") -> NormalizedUtterance:
    original = utterance.strip()
    cleaned = original
    detected = False
    aliases = {wake_word.strip(), "모비", "mobi", "MOBI", "자비스"}
    for alias in sorted((value for value in aliases if value), key=len, reverse=True):
        match = re.match(rf"^\s*{re.escape(alias)}\s*(?:야|아)?\s*[,，]?\s*", cleaned)
        if match:
            cleaned = cleaned[match.end() :].strip()
            detected = True
            break
    return NormalizedUtterance(
        original_utterance=original,
        cleaned_utterance=cleaned,
        wake_word_detected=detected,
        destination_candidate_text=_destination_candidate_text(cleaned),
    )


def classify_agent_intent(
    utterance: str,
    session_state: GuidanceSessionState | None = None,
    *,
    wake_word: str = "모비",
) -> AgentIntentResult:
    normalized = normalize_user_utterance(utterance, wake_word=wake_word)
    text = normalized.cleaned_utterance
    compact = _compact(text)
    if normalized.wake_word_detected and not compact:
        return AgentIntentResult(AgentIntent.WAKE_ONLY, normalized)
    if "못 탔" in text or "못탔" in compact or "놓쳤" in text:
        return AgentIntentResult(AgentIntent.REPORT_MISSED_BUS, normalized)
    if "타도" in text or "타도돼" in compact or "앞에 온 버스" in text:
        return AgentIntentResult(AgentIntent.ASK_CAN_BOARD_CURRENT_BUS, normalized)
    if "아니라" in text:
        return AgentIntentResult(
            AgentIntent.CORRECT_DESTINATION,
            normalized,
            normalized.destination_candidate_text,
        )
    if "바꿔" in text or "변경" in text:
        return AgentIntentResult(
            AgentIntent.CHANGE_DESTINATION,
            normalized,
            normalized.destination_candidate_text,
        )
    if "언제" in text or "몇 분" in text or "몇분" in compact or "도착정보" in compact:
        return AgentIntentResult(AgentIntent.QUERY_ARRIVAL, normalized)
    if "안내해" in text or "오는 걸로" in text or "오는걸로" in compact:
        return AgentIntentResult(AgentIntent.SELECT_ARRIVAL, normalized)
    if any(
        term in compact
        for term in ("몇번", "가야", "가고싶", "가자", "가는법", "어떻게가", "타야")
    ):
        return AgentIntentResult(
            AgentIntent.FIND_ROUTE,
            normalized,
            normalized.destination_candidate_text,
        )
    return AgentIntentResult(AgentIntent.UNKNOWN, normalized)


def resolve_destination_tool(
    text: str,
    origin_lat: float | None,
    origin_lng: float | None,
    mode: str | None,
    *,
    resolver: DestinationCandidateResolver | None = None,
    trace: AgentTraceRecorder | None = None,
) -> DestinationResolveResponse:
    event_id = trace.start(
        "DESTINATION_RESOLVE",
        "목적지 후보 확인",
        operation="resolveDestination",
        safe_payload={"query": text},
    ) if trace else None
    try:
        result = (resolver or DestinationCandidateResolver()).resolve(
            heard_text=text,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
            live=_resolve_live(mode),
        )
    except Exception:
        if trace and event_id:
            trace.fail(event_id, "목적지 후보를 확인하지 못했어.")
        raise
    if trace and event_id:
        trace.done(
            event_id,
            "목적지 후보를 확인했어.",
            safe_payload={
                "query": text,
                "resolutionStatus": result.status.value,
                "candidateCount": len(result.candidates),
                "topCandidate": result.topCandidate.name if result.topCandidate else None,
                "choices": [candidate.name for candidate in result.candidates],
            },
        )
    return result


def match_pending_choice_tool(
    utterance: str,
    pending_candidates: list[Any],
) -> PendingChoiceMatch:
    names = [_candidate_name(candidate) for candidate in pending_candidates]
    names = [name for name in names if name]
    index = _choice_index(utterance)
    if index is not None and 0 <= index < len(names):
        return PendingChoiceMatch(True, names[index], index)

    compact_text = _compact(utterance)
    alias_groups = {
        "고속": ("고속", "고속버스", "고속버스터미널", "청주고속", "청주고속터미널"),
        "시외": ("시외", "시외버스", "시외버스터미널", "청주시외", "청주시외터미널"),
    }
    for keyword, aliases in alias_groups.items():
        if any(_compact(alias) in compact_text or compact_text in _compact(alias) for alias in aliases):
            for candidate_index, name in enumerate(names):
                if keyword in _compact(name):
                    return PendingChoiceMatch(True, name, candidate_index)
    for candidate_index, name in enumerate(names):
        compact_name = _compact(name)
        if compact_name and (compact_name in compact_text or compact_text in compact_name):
            return PendingChoiceMatch(True, name, candidate_index)
    scored = [
        (SequenceMatcher(None, compact_text, _compact(name)).ratio(), candidate_index, name)
        for candidate_index, name in enumerate(names)
        if _compact(name)
    ]
    if scored:
        score, candidate_index, name = max(scored)
        if score >= 0.58:
            return PendingChoiceMatch(True, name, candidate_index)
    return PendingChoiceMatch(False)


def near_destination_guard_tool(
    origin_lat: float,
    origin_lng: float,
    destination: DestinationResolveResponse,
    *,
    trace: AgentTraceRecorder | None = None,
) -> NearDestinationResult:
    candidate = destination.topCandidate
    if candidate is None or candidate.latitude is None or candidate.longitude is None:
        result = NearDestinationResult(False)
        if trace:
            trace.skip(
                "NEAR_DESTINATION_GUARD",
                "목적지 근접 여부 확인",
                "목적지 좌표가 없어 근접 여부 확인을 생략했어.",
            )
        return result
    threshold_name = (
        "CHEONGJU_NEAR_DESTINATION_STOP_METERS"
        if candidate.type == DestinationCandidateType.STOP
        else "CHEONGJU_NEAR_DESTINATION_PLACE_METERS"
    )
    default_threshold = 80.0 if candidate.type == DestinationCandidateType.STOP else 120.0
    try:
        threshold = max(0.0, float(os.getenv(threshold_name, str(default_threshold))))
    except ValueError:
        threshold = default_threshold
    distance = _distance_meters(
        origin_lat,
        origin_lng,
        candidate.latitude,
        candidate.longitude,
    )
    if distance > threshold:
        result = NearDestinationResult(False, distance_meters=distance)
        if trace:
            trace.record(
                "NEAR_DESTINATION_GUARD",
                "목적지 근접 여부 확인 완료",
                "현재 위치와 목적지가 충분히 떨어져 있어 버스 경로를 계산했어.",
                safe_payload={
                    "alreadyNear": False,
                    "distanceMeters": round(distance),
                    "thresholdMeters": threshold,
                },
            )
        return result
    rounded_distance = max(0, int(round(distance / 10.0) * 10))
    result = NearDestinationResult(
        True,
        distance_meters=distance,
        message=(
            f"이미 {candidate.name} 근처야. 도보로 약 {rounded_distance}m 이동하면 돼. "
            "따로 버스를 탈 필요는 없어."
        ),
    )
    if trace:
        trace.record(
            "NEAR_DESTINATION_GUARD",
            "목적지 근접 여부 확인 완료",
            "이미 목적지 근처라 버스 경로 탐색을 생략했어.",
            safe_payload={
                "alreadyNear": True,
                "distanceMeters": round(distance),
                "thresholdMeters": threshold,
            },
        )
    return result


def plan_transit_route_tool(
    destination_text: str,
    origin_lat: float | None,
    origin_lng: float | None,
    mode: str | None,
    *,
    resolver: DestinationCandidateResolver | None = None,
    trace: AgentTraceRecorder | None = None,
) -> RoutePlanResponse:
    live = _resolve_live(mode)
    arrivals_by_route: dict[tuple[str, str, str], V3BusArrivalsResponse] = {}

    def fetch(stop_id: str, route_no: str | None, route_id: str | None = None) -> V3BusArrivalsResponse:
        key = (stop_id.strip(), route_no or "", route_id or "")
        if key not in arrivals_by_route:
            arrivals_by_route[key] = get_arrivals_tool(
                route_id=route_id,
                route_no=route_no,
                stop_id=stop_id,
                mode=mode,
                live=live,
            )
        return arrivals_by_route[key]

    planner = TransitPlannerOrchestrator(
        resolver=resolver or DestinationCandidateResolver(),
        arrival_fetcher=fetch,
    )
    route_plan = verify_route_tool(
        planner.plan(
            heard_text=destination_text,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
            live=live,
        )
    )
    if trace:
        _record_route_plan_trace(
            trace,
            route_plan,
            destination_text=destination_text,
            live=live,
        )
    return route_plan


def verify_route_tool(plan: RoutePlanResponse) -> RoutePlanResponse:
    verified = RoutePlanResponse.model_validate(plan.model_dump(mode="json"))
    if verified.status != RoutePlanStatus.RESOLVED:
        return verified
    if verified.recommendedPlan is None or not verified.recommendedPlan.segments:
        return _invalid_route_plan(verified, "resolved route did not contain a recommendation")

    candidates = [*verified.plans, *verified.alternatives, verified.recommendedPlan]
    for candidate in candidates:
        if not candidate.segments:
            return _invalid_route_plan(verified, "route candidate did not contain segments")
        for segment in candidate.segments:
            if not all(
                (
                    segment.routeNo.strip(),
                    segment.routeId.strip(),
                    segment.boardStop.stopId.strip(),
                    segment.boardStop.stopName.strip(),
                    segment.alightStop.stopId.strip(),
                    segment.alightStop.stopName.strip(),
                )
            ):
                return _invalid_route_plan(verified, "route segment was missing required identifiers")
            segment.arrivals = [
                arrival
                for arrival in segment.arrivals
                if (arrival.routeNo == segment.routeNo or arrival.routeId == segment.routeId)
                and arrival.stopId == segment.boardStop.stopId
            ]
            segment.arrivalUnknown = not segment.arrivals
            segment.estimatedMinutes = min(
                (arrival.arrivalMinutes for arrival in segment.arrivals),
                default=None,
            )
            segment.serviceStatus = get_service_status_tool(
                route_no=segment.routeNo,
                arrivals=segment.arrivals,
            )
        candidate.serviceStatus = candidate.segments[0].serviceStatus
    return verified


def get_arrivals_tool(
    route_id: str | None,
    route_no: str | None,
    stop_id: str,
    mode: str | None,
    *,
    live: bool | None = None,
    trace: AgentTraceRecorder | None = None,
) -> V3BusArrivalsResponse:
    from app.api.routes import v3_bus

    resolved_live = _resolve_live(mode) if live is None else live
    event_id = trace.start(
        "TAGO_ARRIVAL_LOOKUP",
        "도착정보 확인",
        provider="TAGO",
        operation="getArrivals",
        safe_payload={"routeNo": route_no, "stopId": stop_id},
    ) if trace else None
    try:
        result = v3_bus._route_plan_arrivals(
            stop_id,
            route_no=route_no,
            route_id=route_id,
            live=resolved_live,
            mode=mode,
        )
    except Exception:
        if trace and event_id:
            trace.fail(event_id, "도착정보를 확인하지 못했어.")
        raise
    if trace and event_id:
        trace.done(
            event_id,
            "도착 예정 정보를 확인했어.",
            safe_payload={
                "routeNo": route_no,
                "stopId": stop_id,
                "arrivalCount": len(result.arrivals),
                "firstArrivalMinutes": min(
                    (arrival.arrivalMinutes for arrival in result.arrivals),
                    default=None,
                ),
                "fallbackSource": result.fallbackSource.value,
            },
        )
    return result


def get_bus_locations_tool(
    route_id: str | None,
    route_no: str,
    mode: str | None,
    *,
    trace: AgentTraceRecorder | None = None,
) -> NormalizedBusLocationResponse:
    if not route_id or not _resolve_live(mode):
        result = NormalizedBusLocationResponse(routeId=route_id or "", locations=[])
        if trace:
            trace.skip(
                "TAGO_BUS_LOCATION_LOOKUP",
                "버스 위치 확인",
                "실시간 위치 조회가 필요한 단계가 아니라 생략했어.",
                provider="TAGO",
                operation="getBusLocations",
                safe_payload={"routeNo": route_no},
            )
        return result
    event_id = trace.start(
        "TAGO_BUS_LOCATION_LOOKUP",
        "버스 위치 확인",
        provider="TAGO",
        operation="getBusLocations",
        safe_payload={"routeNo": route_no},
    ) if trace else None
    try:
        result = BusLocationService().get_locations("33010", route_id)
    except Exception:
        if trace and event_id:
            trace.fail(event_id, "현재 버스 위치를 확인하지 못했어.")
        raise
    if trace and event_id:
        trace.done(
            event_id,
            "현재 버스 위치를 확인했어.",
            safe_payload={"routeNo": route_no, "locationCount": len(result.locations)},
        )
    return result


def get_route_stops_tool(
    route_id: str | None,
    mode: str | None,
) -> NormalizedBusRouteStopsResponse:
    if not route_id or not _resolve_live(mode):
        return NormalizedBusRouteStopsResponse(routeId=route_id or "", nodes=[])
    return BusRouteService().get_route_stops("33010", route_id)


def get_service_status_tool(
    route_no: str,
    arrivals: list[V3BusArrival],
    now: datetime | None = None,
    *,
    trace: AgentTraceRecorder | None = None,
):
    status = evaluate_route_service_status(route_no=route_no, arrivals=arrivals, now=now)
    if trace:
        trace.record(
            "SERVICE_STATUS_CHECK",
            "운행 시간 확인 완료",
            status.message,
            operation="evaluateServiceWindow",
            safe_payload={
                "routeNo": route_no,
                "operatingNow": status.operatingNow,
                "reason": status.reason,
                "nextServiceLabel": status.nextServiceLabel,
                "scheduleSource": status.scheduleSource,
            },
        )
    return status


def build_grounded_agent_reply_tool(
    route_plan: RoutePlanResponse,
    session_state: GuidanceSessionState | None = None,
    *,
    utterance: str,
    wake_word: str,
    reply_builder: Callable[..., str | None] | None = None,
    history: list[dict] | None = None,
) -> str | None:
    verified = verify_route_tool(route_plan)
    if reply_builder is None:
        from app.services.v3_gemini_service import generate_route_plan_reply

        reply_builder = generate_route_plan_reply
    reply = reply_builder(
        route_plan=verified.model_dump(mode="json"),
        utterance=utterance,
        wake_word=wake_word,
        history=history,
    )
    return sanitize_agent_reply_tool(reply, assistant_name=wake_word)


def sanitize_agent_reply_tool(reply: str | None, assistant_name: str = "모비") -> str | None:
    return _without_vision_claims(reply)


def _record_route_plan_trace(
    trace: AgentTraceRecorder,
    route_plan: RoutePlanResponse,
    *,
    destination_text: str,
    live: bool,
) -> None:
    destination = route_plan.destination
    top_candidate = destination.topCandidate
    trace.record(
        "DESTINATION_RESOLVE",
        "목적지 후보 확인 완료",
        "말한 목적지와 주변 정류장 후보를 확인했어.",
        operation="resolveDestination",
        safe_payload={
            "query": destination_text,
            "resolutionStatus": destination.status.value,
            "candidateCount": len(destination.candidates),
            "topCandidate": top_candidate.name if top_candidate else None,
            "choices": [candidate.name for candidate in destination.candidates],
        },
    )
    kakao_source = top_candidate.source.value if top_candidate else None
    if live and kakao_source == "PUBLIC_API":
        trace.record(
            "KAKAO_PLACE_SEARCH",
            "카카오 장소 검색 완료",
            "카카오 장소 검색에서 목적지 후보를 확인했어.",
            provider="Kakao Local",
            operation="searchPlace",
            safe_payload={
                "query": destination_text,
                "resultCount": len(destination.candidates),
                "topCandidate": top_candidate.name if top_candidate else None,
            },
        )
    else:
        trace.skip(
            "KAKAO_PLACE_SEARCH",
            "카카오 장소 검색",
            "검증된 로컬 후보를 사용해 외부 장소 검색을 생략했어.",
            provider="Kakao Local",
            operation="searchPlace",
            safe_payload={"query": destination_text, "fallbackSource": kakao_source or "NONE"},
        )
    trace.record(
        "NEARBY_STOP_SEARCH",
        "주변 정류장 검색 완료",
        "출발지와 목적지 주변 정류장 후보를 확인했어.",
        operation="searchNearbyStops",
        safe_payload={
            "originStopCount": len(destination.originStops),
            "destinationStopCount": len(destination.destinationStops),
            "topDestinationStop": destination.destinationStops[0].stopName if destination.destinationStops else None,
        },
    )

    already_near = route_plan.status == RoutePlanStatus.ALREADY_NEAR_DESTINATION
    trace.record(
        "NEAR_DESTINATION_GUARD",
        "목적지 근접 여부 확인 완료",
        "이미 목적지 근처라 버스 경로를 생략했어."
        if already_near
        else "버스 경로가 필요한 거리인지 확인했어.",
        safe_payload={"alreadyNear": already_near},
    )

    plans = route_plan.plans
    uses_odsay = any(plan.planSource.value in {"ODSAY", "ODSAY_ENRICHED"} for plan in plans)
    odsay_failed = any("ODsay unavailable" in warning for warning in route_plan.warnings)
    if uses_odsay:
        trace.record(
            "ODSAY_ROUTE_SEARCH",
            "ODsay 경로 탐색 완료",
            "대중교통 경로 후보를 조회했어.",
            provider="ODsay",
            operation="searchPubTransPathT",
            safe_payload={"destination": top_candidate.name if top_candidate else destination_text, "routeCandidateCount": len(plans)},
        )
    elif odsay_failed:
        trace.record(
            "ODSAY_ROUTE_SEARCH",
            "ODsay 경로 탐색 실패",
            "외부 경로 탐색을 완료하지 못해 자체 경로 탐색을 사용했어.",
            status="FAILED",
            provider="ODsay",
            operation="searchPubTransPathT",
            warning="ODsay 실패로 자체 경로 탐색 fallback을 사용했어.",
        )
    else:
        trace.skip(
            "ODSAY_ROUTE_SEARCH",
            "ODsay 경로 탐색",
            "현재 데이터 모드에서는 자체 경로 탐색을 사용했어.",
            provider="ODsay",
            operation="searchPubTransPathT",
        )

    plan = route_plan.recommendedPlan
    segment = plan.segments[0] if plan and plan.segments else None
    if segment is None:
        trace.skip(
            "TAGO_ROUTE_VERIFY",
            "노선 방향 검증",
            "확정된 버스 구간이 없어 노선 방향 검증을 생략했어.",
            provider="TAGO / deterministic validator",
            operation="verifyRouteDirection",
        )
        trace.skip(
            "TAGO_ARRIVAL_LOOKUP",
            "도착정보 확인",
            "확정된 버스 구간이 없어 도착정보 조회를 생략했어.",
            provider="TAGO",
            operation="getArrivals",
        )
        trace.skip(
            "SERVICE_STATUS_CHECK",
            "운행 시간 확인",
            "확정된 노선이 없어 운행 시간 확인을 생략했어.",
            operation="evaluateServiceWindow",
        )
        return

    trace.record(
        "TAGO_ROUTE_VERIFY",
        "노선 방향 검증 완료",
        "선택한 승차·하차 정류장 순서와 노선 방향을 검증했어.",
        provider="TAGO / deterministic validator",
        operation="verifyRouteDirection",
        safe_payload={
            "routeNo": segment.routeNo,
            "boardStop": segment.boardStop.stopName,
            "alightStop": segment.alightStop.stopName,
            "verificationStatus": plan.verificationStatus.value,
        },
    )
    first_arrival = min(segment.arrivals, key=lambda item: item.arrivalMinutes) if segment.arrivals else None
    trace.record(
        "TAGO_ARRIVAL_LOOKUP",
        "도착정보 확인 완료",
        "승차 정류장의 도착 예정 정보를 확인했어."
        if first_arrival
        else "현재 확인 가능한 도착 예정 정보가 없어.",
        provider="TAGO",
        operation="getArrivals",
        safe_payload={
            "routeNo": segment.routeNo,
            "stopName": segment.boardStop.stopName,
            "arrivalCount": len(segment.arrivals),
            "firstArrivalMinutes": first_arrival.arrivalMinutes if first_arrival else None,
            "remainingStops": first_arrival.remainingStops if first_arrival else None,
            "fallbackSource": segment.arrivalSource.value,
        },
    )
    service_status = segment.serviceStatus or evaluate_route_service_status(
        route_no=segment.routeNo,
        arrivals=segment.arrivals,
    )
    trace.record(
        "SERVICE_STATUS_CHECK",
        "운행 시간 확인 완료",
        service_status.message,
        operation="evaluateServiceWindow",
        safe_payload={
            "routeNo": segment.routeNo,
            "operatingNow": service_status.operatingNow,
            "reason": service_status.reason,
            "nextServiceLabel": service_status.nextServiceLabel,
            "scheduleSource": service_status.scheduleSource,
        },
    )


def _invalid_route_plan(plan: RoutePlanResponse, reason: str) -> RoutePlanResponse:
    return plan.model_copy(
        update={
            "status": RoutePlanStatus.ERROR,
            "readiness": RoutePlanReadiness.ERROR,
            "plans": [],
            "recommendedPlan": None,
            "alternatives": [],
            "agentMessage": "검증된 버스 경로를 만들지 못했어.",
            "question": "검증된 버스 경로를 만들지 못했어. 잠시 후 다시 시도해줘.",
            "warnings": list(dict.fromkeys([*plan.warnings, f"route verification failed: {reason}"])),
        }
    )


def _resolve_live(mode: str | None) -> bool:
    if mode:
        return mode.strip().lower() == "live"
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")


def _destination_candidate_text(utterance: str) -> str | None:
    cleaned = utterance.strip()
    cleaned = re.sub(r"^혹시나?\s+", "", cleaned).strip()
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
    return cleaned if len(cleaned) >= 2 and _compact(cleaned) not in {"나", "저"} else None


def _candidate_name(candidate: Any) -> str | None:
    if isinstance(candidate, str):
        return candidate
    if isinstance(candidate, dict):
        name = candidate.get("name")
    else:
        name = getattr(candidate, "name", None)
    return name.strip() if isinstance(name, str) and name.strip() else None


def _choice_index(text: str) -> int | None:
    compact = _compact(text)
    mapping = {
        "1": 0,
        "일번": 0,
        "첫번째": 0,
        "첫째": 0,
        "하나": 0,
        "앞에거": 0,
        "앞의거": 0,
        "2": 1,
        "이번": 1,
        "두번째": 1,
        "둘째": 1,
        "둘": 1,
        "뒤에거": 1,
        "뒤의거": 1,
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


def _compact(text: str) -> str:
    return "".join(character for character in text if character.isalnum())


def _distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6_371_000.0
    lat1_rad = math.radians(lat1)
    lat2_rad = math.radians(lat2)
    delta_lat = math.radians(lat2 - lat1)
    delta_lng = math.radians(lng2 - lng1)
    value = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(delta_lng / 2) ** 2
    )
    return radius * 2 * math.atan2(math.sqrt(value), math.sqrt(1 - value))
