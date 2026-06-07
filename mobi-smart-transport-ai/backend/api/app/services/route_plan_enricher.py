from __future__ import annotations

import math
import re
from collections.abc import Callable
from difflib import SequenceMatcher

from app.schemas.v3 import (
    FallbackSource,
    RoutePlanArrivalSummary,
    RoutePlanCandidate,
    RoutePlanLeg,
    RoutePlanLegMode,
    RoutePlanSegment,
    RoutePlanSource,
    RoutePlanStop,
    RoutePlanVerificationStatus,
    V3BusArrivalsResponse,
)
from app.services.route_direction_resolver import RouteDirectionResolver, sanitize_guidance_text
from app.services.route_service_status import evaluate_route_service_status
from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode, RouteStopSequenceCache


ArrivalFetcher = Callable[..., V3BusArrivalsResponse]


class RoutePlanEnricher:
    """Matches ODsay bus legs to TAGO route sequences and arrival data."""

    def __init__(
        self,
        *,
        sequence_cache: RouteStopSequenceCache,
        arrival_fetcher: ArrivalFetcher | None = None,
    ) -> None:
        self._sequence_cache = sequence_cache
        self._arrival_fetcher = arrival_fetcher
        self._direction_resolver = RouteDirectionResolver()

    def enrich(self, candidate: RoutePlanCandidate, *, live: bool) -> RoutePlanCandidate:
        route_nos = [segment.routeNo for segment in candidate.segments]
        sequences = self._sequence_cache.sequences(live=live, route_nos=route_nos)
        if live:
            # A live ODsay candidate is TAGO-verified only when the matching
            # route sequence actually came from the public API.
            sequences = [sequence for sequence in sequences if sequence.source == FallbackSource.PUBLIC_API]
        warnings: list[str] = []
        enriched_segments: list[RoutePlanSegment] = []
        enriched_legs = list(candidate.legs)
        matched_count = 0
        arrival_summary: RoutePlanArrivalSummary | None = None

        for bus_index, segment in enumerate(candidate.segments):
            match = _match_sequence(sequences, segment)
            if match is None:
                warnings.append(f"{segment.routeNo}번 TAGO routeId/nodeId 매칭 실패")
                enriched_segments.append(segment)
                continue
            sequence, boarding_node, alighting_node = match
            direction_hint = self._direction_resolver.direction_hint(sequence, boarding_node, alighting_node)
            arrivals, arrival_source = self._arrivals_for(
                boarding_node.stop_id,
                route_no=sequence.route_no,
                route_id=sequence.route_id,
            )
            service_status = evaluate_route_service_status(route_no=sequence.route_no, arrivals=arrivals)
            if not arrivals:
                warnings.append(f"{sequence.route_no}번 실시간 도착정보를 확인하지 못함")
            elif bus_index == 0:
                first = min(arrivals, key=lambda item: item.arrivalMinutes)
                arrival_summary = RoutePlanArrivalSummary(
                    arrivalMinutes=first.arrivalMinutes,
                    remainingStops=first.remainingStops,
                    source=arrival_source,
                )
            enriched_segments.append(
                segment.model_copy(
                    update={
                        "routeId": sequence.route_id,
                        "source": "TAGO_ENRICHED",
                        "boardingStopNodeId": boarding_node.stop_id,
                        "alightingStopNodeId": alighting_node.stop_id,
                        "boardStop": _stop(boarding_node, direction_hint=direction_hint),
                        "alightStop": _stop(alighting_node, direction_hint=None),
                        # ODsay stationCount(주행시간 sectionTime과 일관된 구간 정류장 수)를
                        # 보존한다. TAGO 노드 order 차이는 노선이 같은 이름의 정류장을 양방향/
                        # 순환으로 여러 번 지날 때 엉뚱하게 커져(예: 7개 구간이 31로) 주행시간과
                        # 모순됐다. ODsay 값이 없을 때만 TAGO order 차이로 보완한다.
                        "stopCount": (
                            segment.stopCount
                            if segment.stopCount > 0
                            else max(0, alighting_node.order - boarding_node.order)
                        ),
                        "directionHint": direction_hint,
                        "arrivals": arrivals,
                        "arrivalSource": arrival_source,
                        "arrivalUnknown": not arrivals,
                        "serviceStatus": service_status,
                    }
                )
            )
            enriched_legs = _update_bus_leg(
                enriched_legs,
                bus_index=bus_index,
                sequence=sequence,
                boarding_node=boarding_node,
                alighting_node=alighting_node,
                direction_hint=direction_hint,
            )
            matched_count += 1

        status = _verification_status(matched_count, len(candidate.segments))
        warnings = _dedupe(warnings)
        return candidate.model_copy(
            update={
                "planSource": (
                    RoutePlanSource.ODSAY_ENRICHED
                    if status == RoutePlanVerificationStatus.VERIFIED_WITH_TAGO
                    else RoutePlanSource.ODSAY
                ),
                "verificationStatus": status,
                "warnings": warnings,
                "segments": enriched_segments,
                "legs": enriched_legs,
                "arrival": arrival_summary,
                "boardingInstruction": _boarding_instruction(enriched_segments[0]),
                "rawProviderEvidence": {
                    **candidate.rawProviderEvidence,
                    "matchedBusLegs": matched_count,
                    "totalBusLegs": len(candidate.segments),
                },
                "serviceStatus": enriched_segments[0].serviceStatus if enriched_segments else None,
            }
        )

    def _arrivals_for(
        self,
        stop_id: str,
        *,
        route_no: str,
        route_id: str,
    ) -> tuple[list, FallbackSource]:
        if self._arrival_fetcher is None:
            return [], FallbackSource.ERROR
        try:
            try:
                response = self._arrival_fetcher(stop_id, route_no, route_id)
            except TypeError:
                response = self._arrival_fetcher(stop_id, route_no)
        except Exception:
            return [], FallbackSource.ERROR
        arrivals = [item for item in response.arrivals if item.routeNo == route_no or item.routeId == route_id]
        return arrivals, response.fallbackSource


def _match_sequence(
    sequences: list[RouteSequence],
    segment: RoutePlanSegment,
) -> tuple[RouteSequence, RouteStopNode, RouteStopNode] | None:
    best: tuple[float, RouteSequence, RouteStopNode, RouteStopNode] | None = None
    for sequence in sequences:
        if _normalize_route_no(sequence.route_no) != _normalize_route_no(segment.routeNo):
            continue
        for boarding_node in sequence.nodes:
            board_score = _stop_match_score(segment.boardStop, boarding_node)
            if board_score < 0.58:
                continue
            for alighting_node in sequence.nodes:
                if boarding_node.order >= alighting_node.order:
                    continue
                alight_score = _stop_match_score(segment.alightStop, alighting_node)
                if alight_score < 0.58:
                    continue
                score = board_score + alight_score
                if best is None or score > best[0]:
                    best = (score, sequence, boarding_node, alighting_node)
    if best is None:
        return None
    _, sequence, boarding_node, alighting_node = best
    return sequence, boarding_node, alighting_node


def _stop(node: RouteStopNode, *, direction_hint: str | None) -> RoutePlanStop:
    return RoutePlanStop(
        stopId=node.stop_id,
        nodeId=node.stop_id,
        stopName=sanitize_guidance_text(node.stop_name) or "정류장",
        latitude=node.latitude,
        longitude=node.longitude,
        order=node.order,
        directionHint=direction_hint,
        sideHint=None,
        visionRequiredForSideHint=True,
    )


def _update_bus_leg(
    legs: list[RoutePlanLeg],
    *,
    bus_index: int,
    sequence: RouteSequence,
    boarding_node: RouteStopNode,
    alighting_node: RouteStopNode,
    direction_hint: str | None,
) -> list[RoutePlanLeg]:
    out: list[RoutePlanLeg] = []
    current_bus_index = 0
    for leg in legs:
        if leg.mode != RoutePlanLegMode.BUS:
            out.append(leg)
            continue
        if current_bus_index == bus_index:
            leg = leg.model_copy(
                update={
                    "routeId": sequence.route_id,
                    "boardingStopNodeId": boarding_node.stop_id,
                    "alightingStopNodeId": alighting_node.stop_id,
                    "directionHint": direction_hint,
                    "source": "TAGO_ENRICHED",
                }
            )
        current_bus_index += 1
        out.append(leg)
    return out


def _boarding_instruction(segment: RoutePlanSegment) -> str:
    direction_text = f", {segment.directionHint} 정류장" if segment.directionHint else ""
    first_arrival = min((item.arrivalMinutes for item in segment.arrivals), default=None)
    arrival_text = (
        f" 현재 약 {first_arrival}분 뒤 도착 예정입니다."
        if first_arrival is not None
        else f" {segment.serviceStatus.message}"
        if segment.serviceStatus is not None
        else " 실시간 도착정보는 확인하지 못했어요."
    )
    return f"{segment.boardStop.stopName}{direction_text}에서 {segment.routeNo}번을 타시면 됩니다.{arrival_text}"


def _verification_status(matched: int, total: int) -> RoutePlanVerificationStatus:
    if matched == total and total > 0:
        return RoutePlanVerificationStatus.VERIFIED_WITH_TAGO
    if matched > 0:
        return RoutePlanVerificationStatus.PARTIAL
    return RoutePlanVerificationStatus.ODSAY_ONLY


def _normalize_route_no(value: str) -> str:
    return re.sub(r"\s+", "", value).lower()


def _normalize_stop_name(value: str) -> str:
    normalized = re.sub(r"[\s\-_.,()/·]+", "", value or "").lower()
    for suffix in ("버스정류장", "정류장", "승강장", "정류소"):
        normalized = normalized.replace(suffix, "")
    for prefix in ("충청북도", "충북", "청주시"):
        normalized = normalized.replace(prefix, "")
    return normalized


def _candidate_stop_names(value: str) -> list[str]:
    raw = value or ""
    candidates = [raw]
    candidates.extend(part for part in re.split(r"[.·,/()]", raw) if part)
    out: list[str] = []
    for candidate in candidates:
        normalized = _normalize_stop_name(candidate)
        if normalized and normalized not in out:
            out.append(normalized)
    return out


def _stop_match_score(stop: RoutePlanStop, node: RouteStopNode) -> float:
    stop_ids = {
        value.strip()
        for value in (stop.stopId, stop.nodeId)
        if value and value.strip() and not value.startswith("odsay-unverified")
    }
    if node.stop_id and node.stop_id in stop_ids:
        return 1.0

    provider_names = _candidate_stop_names(stop.stopName)
    sequence_name = _normalize_stop_name(node.stop_name)
    name_score = 0.0
    for provider_name in provider_names:
        if not provider_name or not sequence_name:
            continue
        if provider_name == sequence_name:
            name_score = max(name_score, 0.96)
        elif provider_name in sequence_name or sequence_name in provider_name:
            name_score = max(name_score, 0.86)
        else:
            name_score = max(name_score, SequenceMatcher(None, provider_name, sequence_name).ratio())

    coordinate_score = _coordinate_match_score(stop, node)
    return max(name_score, coordinate_score)


def _coordinate_match_score(stop: RoutePlanStop, node: RouteStopNode) -> float:
    if (
        stop.latitude is None
        or stop.longitude is None
        or node.latitude is None
        or node.longitude is None
    ):
        return 0.0
    distance = _distance_meters(stop.latitude, stop.longitude, node.latitude, node.longitude)
    if distance <= 40:
        return 0.96
    if distance <= 80:
        return 0.82
    if distance <= 140:
        return 0.62
    return 0.0


def _stop_name_matches(normalized_provider_name: str, sequence_name: str) -> bool:
    normalized_sequence_name = _normalize_stop_name(sequence_name)
    return bool(
        normalized_provider_name
        and normalized_sequence_name
        and (
            normalized_provider_name == normalized_sequence_name
            or normalized_provider_name in normalized_sequence_name
            or normalized_sequence_name in normalized_provider_name
        )
    )


def _distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lng2 - lng1)
    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return 2 * radius * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _dedupe(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))
