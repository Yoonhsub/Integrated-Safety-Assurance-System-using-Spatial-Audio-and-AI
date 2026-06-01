from __future__ import annotations

import re
from collections.abc import Callable

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
                        "stopCount": max(0, alighting_node.order - boarding_node.order),
                        "directionHint": direction_hint,
                        "arrivals": arrivals,
                        "arrivalSource": arrival_source,
                        "arrivalUnknown": not arrivals,
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
    boarding_name = _normalize_stop_name(segment.boardStop.stopName)
    alighting_name = _normalize_stop_name(segment.alightStop.stopName)
    for sequence in sequences:
        if _normalize_route_no(sequence.route_no) != _normalize_route_no(segment.routeNo):
            continue
        for boarding_node in sequence.nodes:
            if not _stop_name_matches(boarding_name, boarding_node.stop_name):
                continue
            for alighting_node in sequence.nodes:
                if boarding_node.order >= alighting_node.order:
                    continue
                if _stop_name_matches(alighting_name, alighting_node.stop_name):
                    return sequence, boarding_node, alighting_node
    return None


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
        f" 현재 약 {first_arrival}분 뒤 도착 예정이야."
        if first_arrival is not None
        else " 실시간 도착정보는 확인하지 못했어."
    )
    return f"{segment.boardStop.stopName}{direction_text}에서 {segment.routeNo}번을 타면 돼.{arrival_text}"


def _verification_status(matched: int, total: int) -> RoutePlanVerificationStatus:
    if matched == total and total > 0:
        return RoutePlanVerificationStatus.VERIFIED_WITH_TAGO
    if matched > 0:
        return RoutePlanVerificationStatus.PARTIAL
    return RoutePlanVerificationStatus.ODSAY_ONLY


def _normalize_route_no(value: str) -> str:
    return re.sub(r"\s+", "", value).lower()


def _normalize_stop_name(value: str) -> str:
    return re.sub(r"[\s\-_.,()]+", "", value).replace("정류장", "").lower()


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


def _dedupe(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))
