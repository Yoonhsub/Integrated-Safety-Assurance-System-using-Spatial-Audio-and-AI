from __future__ import annotations

import os
from typing import Callable, Iterable

from app.schemas.v3 import (
    DestinationCandidateType,
    DestinationResolveResponse,
    DestinationResolveStatus,
    FallbackSource,
    NearbyStopCandidate,
    RoutePlanCandidate,
    RoutePlanReadiness,
    RoutePlanResponse,
    RoutePlanSegment,
    RoutePlanStatus,
    RoutePlanStop,
    RoutePlanType,
    V3BusArrival,
    V3BusArrivalsResponse,
)
from app.services.destination_candidate_resolver import DestinationCandidateResolver
from app.services.direct_bus_planner import (
    MatchedStop,
    RawRoutePlan,
    matches_for as _direct_matches_for,
    stop_matches as _direct_stop_matches,
)
from app.services.direct_bus_planner import DirectBusPlanner
from app.services.route_direction_resolver import RouteDirectionResolver, sanitize_guidance_text
from app.services.route_ranker import RouteRanker
from app.services.route_service_status import evaluate_route_service_status
from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode, RouteStopSequenceCache
from app.services.transfer_bus_planner import TransferBusPlanner
from services.public_data.public_data_client import BusRouteService

CHEONGJU_CITY_CODE = "33010"

_MAX_ORIGIN_STOPS = 5
_MAX_DESTINATION_STOPS = 5
_MAX_PLANS = 5
_MAX_RAW_PLANS_TO_ENRICH = 20
_DEFAULT_ROUTE_NOS = ("502", "823", "862", "863", "864")

ArrivalFetcher = Callable[..., V3BusArrivalsResponse]


class CheongjuRoutePlanner:
    """Composes deterministic direct, transfer, direction, arrival, and rank services."""

    def __init__(
        self,
        *,
        resolver: DestinationCandidateResolver | None = None,
        route_service: BusRouteService | None = None,
        arrival_fetcher: ArrivalFetcher | None = None,
        sequence_cache: RouteStopSequenceCache | None = None,
    ) -> None:
        self._resolver = resolver or DestinationCandidateResolver()
        self._arrival_fetcher = arrival_fetcher
        self._sequence_cache = sequence_cache or RouteStopSequenceCache(
            route_service=route_service or BusRouteService(),
            city_code=CHEONGJU_CITY_CODE,
            mock_sequences=_mock_route_sequences(),
        )
        self._direct_planner = DirectBusPlanner()
        self._transfer_planner = TransferBusPlanner()
        self._direction_resolver = RouteDirectionResolver()
        self._ranker = RouteRanker()

    def plan(
        self,
        *,
        heard_text: str,
        origin_lat: float | None = None,
        origin_lng: float | None = None,
        live: bool = False,
        use_live_sequences: bool | None = None,
    ) -> RoutePlanResponse:
        destination = self._resolver.resolve(
            heard_text=heard_text,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
            live=live,
        )
        if destination.status != DestinationResolveStatus.RESOLVED:
            return self._empty_response(
                status=RoutePlanStatus(destination.status.value),
                destination=destination,
                heard_text=heard_text,
                question=destination.question,
            )
        near_message = _near_destination_message(
            destination,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
        )
        if near_message is not None:
            return self._empty_response(
                status=RoutePlanStatus.ALREADY_NEAR_DESTINATION,
                destination=destination,
                heard_text=heard_text,
                question=near_message,
            )
        if not destination.originStops:
            return self._empty_response(
                status=RoutePlanStatus.NOT_FOUND,
                destination=destination,
                heard_text=heard_text,
                question="현재 위치 주변 승차 정류장을 찾지 못했어요. 위치 권한을 확인해 주세요.",
            )
        if not destination.destinationStops:
            return self._empty_response(
                status=RoutePlanStatus.NOT_FOUND,
                destination=destination,
                heard_text=heard_text,
                question="목적지 주변 하차 정류장을 찾지 못했어요. 목적지를 조금 더 정확히 말씀해 주세요.",
            )

        sequence_live = live if use_live_sequences is None else use_live_sequences
        raw_plans = self._find_plans(destination=destination, sequences=self._route_sequences(live=sequence_live))
        candidates = [
            self._to_candidate(index, raw)
            for index, raw in enumerate(raw_plans[:_MAX_RAW_PLANS_TO_ENRICH], start=1)
        ]
        plans = self._ranker.rank(candidates)[:_MAX_PLANS]
        recommended = plans[0] if plans else None
        fallback = _strongest_source([destination.fallbackSource, *(plan.fallbackSource for plan in plans)])
        if recommended is None:
            # 버스 경로가 없더라도 목적지가 도보 가능한 거리면 실패로 끝내지 않고
            # 보행 안내를 제공한다. (짧은 거리에서 "경로를 찾지 못했어"로 막히던 문제)
            walk_message = _walkable_destination_message(
                destination, origin_lat=origin_lat, origin_lng=origin_lng
            )
            if walk_message is not None:
                return self._empty_response(
                    status=RoutePlanStatus.ALREADY_NEAR_DESTINATION,
                    destination=destination,
                    heard_text=heard_text,
                    question=walk_message,
                )
        question = None if recommended else "현재 후보 정류장 조합으로 갈 수 있는 직통 또는 1회 환승 경로를 찾지 못했어요."
        return RoutePlanResponse(
            status=RoutePlanStatus.RESOLVED if recommended else RoutePlanStatus.NO_ROUTE,
            readiness=RoutePlanReadiness.READY if recommended else RoutePlanReadiness.NO_ROUTE,
            heardText=heard_text,
            destination=destination,
            plans=plans,
            recommendedPlan=recommended,
            alternatives=plans[1:],
            agentMessage=recommended.boardingInstruction if recommended else question,
            question=question,
            fallbackSource=fallback,
        )

    def _empty_response(
        self,
        *,
        status: RoutePlanStatus,
        destination: DestinationResolveResponse,
        heard_text: str,
        question: str | None,
    ) -> RoutePlanResponse:
        return RoutePlanResponse(
            status=status,
            readiness=RoutePlanReadiness(status.value),
            heardText=heard_text,
            destination=destination,
            plans=[],
            recommendedPlan=None,
            alternatives=[],
            agentMessage=question,
            question=question,
            fallbackSource=destination.fallbackSource,
        )

    def _route_sequences(self, *, live: bool) -> list[RouteSequence]:
        return self._sequence_cache.sequences(live=live, route_nos=_configured_route_nos())

    def _find_plans(
        self,
        *,
        destination: DestinationResolveResponse,
        sequences: list[RouteSequence],
    ) -> list[RawRoutePlan]:
        destination_name = destination.topCandidate.name if destination.topCandidate else destination.normalizedText
        kwargs = {
            "destination_name": destination_name,
            "origin_candidates": destination.originStops[:_MAX_ORIGIN_STOPS],
            "destination_candidates": destination.destinationStops[:_MAX_DESTINATION_STOPS],
            "sequences": sequences,
        }
        raw_plans = [
            *self._direct_planner.find_plans(**kwargs),
            *self._transfer_planner.find_plans(**kwargs),
        ]
        unique: dict[tuple, RawRoutePlan] = {}
        for raw in raw_plans:
            key = tuple(
                (sequence.route_id, board.node.stop_id, alight.node.stop_id)
                for sequence, board, alight in raw.segments
            )
            unique.setdefault(key, raw)
        return sorted(
            unique.values(),
            key=lambda raw: (
                len(raw.segments),
                raw.estimated_walk_meters,
                sum(alight.node.order - board.node.order for _, board, alight in raw.segments),
            ),
        )

    def _to_candidate(self, index: int, raw: RawRoutePlan) -> RoutePlanCandidate:
        segments = [self._to_segment(sequence, board, alight) for sequence, board, alight in raw.segments]
        plan_type = RoutePlanType.DIRECT if len(segments) == 1 else RoutePlanType.ONE_TRANSFER
        transfer_count = len(segments) - 1
        return RoutePlanCandidate(
            planId=f"plan-{index}",
            type=plan_type,
            destinationName=raw.destination_name,
            summary=_summary(plan_type, segments, raw.destination_name),
            boardingInstruction=_boarding_instruction(segments[0]) if segments else "승차 경로를 찾지 못했어요.",
            transferCount=transfer_count,
            totalBusStopCount=sum(segment.stopCount for segment in segments),
            estimatedWalkMeters=round(raw.estimated_walk_meters, 1),
            accessibilityScore=0,
            simplicityScore=0,
            score=0,
            segments=segments,
            fallbackSource=raw.fallback_source,
            serviceStatus=segments[0].serviceStatus if segments else None,
        )

    def _to_segment(
        self,
        sequence: RouteSequence,
        board: MatchedStop,
        alight: MatchedStop,
    ) -> RoutePlanSegment:
        direction_hint = self._direction_resolver.direction_hint(sequence, board.node, alight.node)
        arrivals, arrival_source = self._arrivals_for(board.node.stop_id, sequence.route_no, sequence.route_id)
        service_status = evaluate_route_service_status(route_no=sequence.route_no, arrivals=arrivals)
        return RoutePlanSegment(
            routeNo=sequence.route_no,
            routeId=sequence.route_id,
            boardStop=_route_plan_stop(board.candidate, board.node, direction_hint=direction_hint),
            alightStop=_route_plan_stop(alight.candidate, alight.node, direction_hint=f"{alight.node.stop_name} 방향"),
            stopCount=max(0, alight.node.order - board.node.order),
            directionHint=direction_hint,
            arrivals=arrivals,
            arrivalSource=arrival_source,
            arrivalUnknown=not arrivals,
            estimatedMinutes=min((arrival.arrivalMinutes for arrival in arrivals), default=None),
            serviceStatus=service_status,
        )

    def _arrivals_for(
        self,
        stop_id: str,
        route_no: str,
        route_id: str,
    ) -> tuple[list[V3BusArrival], FallbackSource]:
        if self._arrival_fetcher is None:
            return [], FallbackSource.ERROR
        try:
            try:
                response = self._arrival_fetcher(stop_id, route_no, route_id)
            except TypeError:
                response = self._arrival_fetcher(stop_id, route_no)
        except Exception:
            return [], FallbackSource.ERROR
        arrivals = [
            item
            for item in response.arrivals
            if item.routeNo == route_no or item.routeId == route_id
        ]
        return arrivals, response.fallbackSource


def _mock_route_sequences() -> list[RouteSequence]:
    return [
        RouteSequence(
            route_no="502",
            route_id="mock-route-502-west-east",
            source=FallbackSource.MOCK,
            nodes=(
                RouteStopNode("mock-stop-003", "청주고속버스터미널 정류장", 1, 36.6262, 127.4312),
                RouteStopNode("mock-stop-001", "사창사거리 정류장", 2, 36.63594787, 127.4596675),
                RouteStopNode("seed-stop-cheongju-gym", "청주체육관 정류장", 3, 36.6370, 127.4740),
                RouteStopNode("seed-stop-cityhall", "청주시청 정류장", 4, 36.6424, 127.4890),
                RouteStopNode("seed-stop-cheongju-univ", "청주대학교 정류장", 5, 36.650856501, 127.49519913),
            ),
        ),
        RouteSequence(
            route_no="502",
            route_id="mock-route-502-east-west",
            source=FallbackSource.MOCK,
            nodes=(
                RouteStopNode("seed-stop-cheongju-univ", "청주대학교 정류장", 1, 36.650856501, 127.49519913),
                RouteStopNode("seed-stop-cityhall-opposite", "청주시청 정류장", 2, 36.6422, 127.4892),
                RouteStopNode("seed-stop-cheongju-gym-opposite", "청주체육관 정류장", 3, 36.6368, 127.4743),
                RouteStopNode("mock-stop-001-opposite", "사창사거리 정류장", 4, 36.6350, 127.4610),
                RouteStopNode("mock-stop-003", "청주고속버스터미널 정류장", 5, 36.6262, 127.4312),
            ),
        ),
        RouteSequence(
            route_no="823",
            route_id="mock-route-823",
            source=FallbackSource.MOCK,
            nodes=(
                RouteStopNode("mock-stop-001", "사창사거리 정류장", 1, 36.63594787, 127.4596675),
                RouteStopNode("mock-stop-002", "충북대학교병원 정류장", 2, 36.6242, 127.4613),
                RouteStopNode("seed-stop-gaesin", "개신오거리 정류장", 3, 36.6200, 127.4550),
            ),
        ),
        RouteSequence(
            route_no="862",
            route_id="mock-route-862-to-fortress",
            source=FallbackSource.MOCK,
            nodes=(
                RouteStopNode("mock-stop-001", "사창사거리 정류장", 1, 36.63594787, 127.4596675),
                RouteStopNode("seed-stop-cheongju-gym", "청주체육관 정류장", 2, 36.6370, 127.4740),
                RouteStopNode("seed-stop-sangdang-south-gate", "산성남문 정류장", 3, 36.6587, 127.5360),
                RouteStopNode("seed-stop-sangdang-fortress", "상당산성 정류장", 4, 36.6613, 127.5329),
            ),
        ),
        RouteSequence(
            route_no="862",
            route_id="mock-route-862-from-fortress",
            source=FallbackSource.MOCK,
            nodes=(
                RouteStopNode("seed-stop-sangdang-fortress", "상당산성 정류장", 1, 36.6613, 127.5329),
                RouteStopNode("seed-stop-sangdang-south-gate", "산성남문 정류장", 2, 36.6587, 127.5360),
                RouteStopNode("seed-stop-cheongju-gym-opposite", "청주체육관 정류장", 3, 36.6368, 127.4743),
                RouteStopNode("mock-stop-001-opposite", "사창사거리 정류장", 4, 36.6350, 127.4610),
            ),
        ),
    ]


def _configured_route_nos() -> tuple[str, ...]:
    raw = os.getenv("CHEONGJU_ROUTE_PLAN_ROUTE_NOS", "").strip()
    if not raw:
        return _DEFAULT_ROUTE_NOS
    values = tuple(item.strip() for item in raw.split(",") if item.strip())
    return values or _DEFAULT_ROUTE_NOS


def _matches_for(sequence: RouteSequence, candidates: Iterable[NearbyStopCandidate]) -> list[MatchedStop]:
    return sorted(
        _direct_matches_for(sequence, list(candidates)),
        key=lambda item: (item.node.order, float(item.candidate.distanceMeters or 0)),
    )


def _stop_matches(candidate: NearbyStopCandidate, node: RouteStopNode) -> bool:
    return _direct_stop_matches(node, candidate)


def _route_plan_stop(
    candidate: NearbyStopCandidate,
    node: RouteStopNode,
    *,
    direction_hint: str | None,
) -> RoutePlanStop:
    return RoutePlanStop(
        stopId=node.stop_id or candidate.stopId,
        stopName=sanitize_guidance_text(node.stop_name or candidate.stopName) or "정류장",
        latitude=node.latitude if node.latitude is not None else candidate.latitude,
        longitude=node.longitude if node.longitude is not None else candidate.longitude,
        distanceMeters=candidate.distanceMeters,
        order=node.order,
        directionHint=direction_hint or candidate.directionHint,
        sideHint=candidate.sideHint,
        visionRequiredForSideHint=candidate.visionRequiredForSideHint or candidate.sideHint is None,
        crossStreetHint=candidate.crossStreetHint,
    )


def _summary(plan_type: RoutePlanType, segments: list[RoutePlanSegment], destination: str) -> str:
    if not segments:
        return f"{destination}까지 계산된 경로가 없습니다."
    if plan_type == RoutePlanType.DIRECT:
        first = segments[0]
        return f"{first.routeNo}번 직통으로 {first.alightStop.stopName}에서 내려 {destination}까지 가는 경로입니다."
    first, second = segments[0], segments[1]
    return (
        f"{first.routeNo}번을 타고 {first.alightStop.stopName}에서 내린 뒤 "
        f"{second.routeNo}번으로 한 번 갈아타고 {second.alightStop.stopName}에서 내리는 경로예요."
    )


def _boarding_instruction(segment: RoutePlanSegment) -> str:
    direction = segment.directionHint or segment.boardStop.directionHint or f"{segment.alightStop.stopName} 방향"
    first_arrival = min((item.arrivalMinutes for item in segment.arrivals), default=None)
    arrival_text = (
        f" 지금 기준 첫 차는 약 {first_arrival}분 뒤 도착 예정입니다."
        if first_arrival is not None
        else f" {segment.serviceStatus.message}"
        if segment.serviceStatus is not None
        else " 첫 차 도착정보는 아직 확인되지 않았습니다."
    )
    return f"{segment.boardStop.stopName}, {direction} 정류장에서 {segment.routeNo}번을 타시면 됩니다.{arrival_text}"


def _near_destination_message(
    destination: DestinationResolveResponse,
    *,
    origin_lat: float | None,
    origin_lng: float | None,
) -> str | None:
    candidate = destination.topCandidate
    if (
        candidate is None
        or candidate.latitude is None
        or candidate.longitude is None
        or origin_lat is None
        or origin_lng is None
    ):
        return None

    threshold = _near_destination_threshold(candidate.type)
    distance = _distance_meters(origin_lat, origin_lng, candidate.latitude, candidate.longitude)
    if distance > threshold:
        return None
    rounded_distance = max(0, int(round(distance / 10.0) * 10))
    return f"이미 {candidate.name} 근처예요. 도보로 약 {rounded_distance}m 이동하시면 됩니다. 따로 버스를 타실 필요는 없습니다."


def _walkable_destination_message(
    destination: DestinationResolveResponse,
    *,
    origin_lat: float | None,
    origin_lng: float | None,
) -> str | None:
    candidate = destination.topCandidate
    if (
        candidate is None
        or candidate.latitude is None
        or candidate.longitude is None
        or origin_lat is None
        or origin_lng is None
    ):
        return None
    try:
        threshold = max(0.0, float(os.getenv("CHEONGJU_WALKABLE_DESTINATION_METERS", "1500")))
    except ValueError:
        threshold = 1500.0
    distance = _distance_meters(origin_lat, origin_lng, candidate.latitude, candidate.longitude)
    if distance > threshold:
        return None
    rounded = max(0, int(round(distance / 10.0) * 10))
    minutes = max(1, int(round(distance / 67.0)))  # 보행 약 4km/h 기준
    return (
        f"{candidate.name}까지는 버스보다 걷는 게 빨라요. "
        f"도보로 약 {rounded}m, {minutes}분 정도 거리입니다. 보행 경로로 안내해 드릴게요."
    )


def _near_destination_threshold(candidate_type: DestinationCandidateType) -> float:
    env_name = (
        "CHEONGJU_NEAR_DESTINATION_STOP_METERS"
        if candidate_type == DestinationCandidateType.STOP
        else "CHEONGJU_NEAR_DESTINATION_PLACE_METERS"
    )
    default = 80.0 if candidate_type == DestinationCandidateType.STOP else 120.0
    try:
        return max(0.0, float(os.getenv(env_name, str(default))))
    except ValueError:
        return default


def _distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    from math import asin, cos, radians, sin, sqrt

    d_lat = radians(lat2 - lat1)
    d_lng = radians(lng2 - lng1)
    a = sin(d_lat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(d_lng / 2) ** 2
    return 2 * 6371000.0 * asin(sqrt(a))


def _strongest_source(sources: Iterable[FallbackSource]) -> FallbackSource:
    priority = {
        FallbackSource.PUBLIC_API: 4,
        FallbackSource.CACHE: 3,
        FallbackSource.GEMINI: 2,
        FallbackSource.MOCK: 1,
        FallbackSource.ERROR: 0,
    }
    return max(sources, key=lambda source: priority[source], default=FallbackSource.ERROR)
