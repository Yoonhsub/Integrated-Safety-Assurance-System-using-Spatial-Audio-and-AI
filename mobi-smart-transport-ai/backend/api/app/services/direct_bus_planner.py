from __future__ import annotations

from dataclasses import dataclass
from math import atan2, cos, radians, sin, sqrt
from typing import Sequence

from app.schemas.v3 import FallbackSource, NearbyStopCandidate
from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode


@dataclass(frozen=True)
class MatchedStop:
    node: RouteStopNode
    candidate: NearbyStopCandidate


@dataclass(frozen=True)
class RawRoutePlan:
    destination_name: str
    segments: tuple[tuple[RouteSequence, MatchedStop, MatchedStop], ...]
    estimated_walk_meters: int
    fallback_source: FallbackSource


class DirectBusPlanner:
    def find_plans(
        self,
        *,
        destination_name: str,
        origin_candidates: Sequence[NearbyStopCandidate],
        destination_candidates: Sequence[NearbyStopCandidate],
        sequences: Sequence[RouteSequence],
    ) -> list[RawRoutePlan]:
        plans: list[RawRoutePlan] = []
        for sequence in sequences:
            board_matches = matches_for(sequence, origin_candidates)
            alight_matches = matches_for(sequence, destination_candidates)
            for board in board_matches:
                for alight in alight_matches:
                    if board.node.order >= alight.node.order:
                        continue
                    plans.append(
                        RawRoutePlan(
                            destination_name=destination_name,
                            segments=((sequence, board, alight),),
                            estimated_walk_meters=float(board.candidate.distanceMeters or 0)
                            + float(alight.candidate.distanceMeters or 0),
                            fallback_source=_strongest_source(sequence.source, board.candidate.source, alight.candidate.source),
                        )
                    )
        return plans


def matches_for(
    sequence: RouteSequence,
    candidates: Sequence[NearbyStopCandidate],
) -> list[MatchedStop]:
    matches: list[MatchedStop] = []
    for node in sequence.nodes:
        for candidate in candidates:
            if stop_matches(node, candidate):
                matches.append(MatchedStop(node=node, candidate=candidate))
    return matches


def stop_matches(node: RouteStopNode, candidate: NearbyStopCandidate) -> bool:
    if node.stop_id and candidate.stopId:
        return node.stop_id == candidate.stopId
    if _normalize_stop_name(node.stop_name) == _normalize_stop_name(candidate.stopName):
        return True
    if None not in (node.latitude, node.longitude, candidate.latitude, candidate.longitude):
        return _distance_meters(node.latitude, node.longitude, candidate.latitude, candidate.longitude) <= 80
    return False


def _normalize_stop_name(value: str) -> str:
    return "".join(value.split()).replace("정류장", "")


def _distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> int:
    radius = 6_371_000
    lat1_rad = radians(lat1)
    lat2_rad = radians(lat2)
    delta_lat = radians(lat2 - lat1)
    delta_lng = radians(lng2 - lng1)
    a = sin(delta_lat / 2) ** 2 + cos(lat1_rad) * cos(lat2_rad) * sin(delta_lng / 2) ** 2
    return round(radius * 2 * atan2(sqrt(a), sqrt(1 - a)))


def _strongest_source(*sources: FallbackSource) -> FallbackSource:
    if FallbackSource.PUBLIC_API in sources:
        return FallbackSource.PUBLIC_API
    if FallbackSource.CACHE in sources:
        return FallbackSource.CACHE
    return FallbackSource.MOCK
