from __future__ import annotations

from math import atan2, cos, radians, sin, sqrt
from typing import Sequence

from app.schemas.v3 import FallbackSource, NearbyStopCandidate
from app.services.direct_bus_planner import MatchedStop, RawRoutePlan, matches_for
from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode


class TransferBusPlanner:
    def __init__(self, *, max_transfer_walk_meters: int = 120) -> None:
        self._max_transfer_walk_meters = max_transfer_walk_meters

    def find_plans(
        self,
        *,
        destination_name: str,
        origin_candidates: Sequence[NearbyStopCandidate],
        destination_candidates: Sequence[NearbyStopCandidate],
        sequences: Sequence[RouteSequence],
    ) -> list[RawRoutePlan]:
        plans: list[RawRoutePlan] = []
        for first in sequences:
            board_matches = matches_for(first, origin_candidates)
            if not board_matches:
                continue
            for second in sequences:
                if first.route_id == second.route_id or first.route_no == second.route_no:
                    continue
                alight_matches = matches_for(second, destination_candidates)
                if not alight_matches:
                    continue
                for board in board_matches:
                    for alight in alight_matches:
                        for first_transfer, second_transfer, transfer_walk in self._transfer_pairs(first, second):
                            if board.node.order >= first_transfer.node.order:
                                continue
                            if second_transfer.node.order >= alight.node.order:
                                continue
                            plans.append(
                                RawRoutePlan(
                                    destination_name=destination_name,
                                    segments=(
                                        (first, board, first_transfer),
                                        (second, second_transfer, alight),
                                    ),
                                    estimated_walk_meters=float(board.candidate.distanceMeters or 0)
                                    + transfer_walk
                                    + float(alight.candidate.distanceMeters or 0),
                                    fallback_source=_strongest_source(
                                        first.source,
                                        second.source,
                                        board.candidate.source,
                                        alight.candidate.source,
                                    ),
                                )
                            )
        return plans

    def _transfer_pairs(
        self,
        first: RouteSequence,
        second: RouteSequence,
    ) -> list[tuple[MatchedStop, MatchedStop, int]]:
        pairs: list[tuple[MatchedStop, MatchedStop, int]] = []
        for first_node in first.nodes:
            for second_node in second.nodes:
                walk_meters = _transfer_walk_meters(first_node, second_node)
                if not _same_transfer_stop(first_node, second_node, walk_meters, self._max_transfer_walk_meters):
                    continue
                pairs.append(
                    (
                        MatchedStop(first_node, _transfer_candidate(first_node)),
                        MatchedStop(second_node, _transfer_candidate(second_node)),
                        walk_meters,
                    )
                )
        return pairs


def _same_transfer_stop(
    first: RouteStopNode,
    second: RouteStopNode,
    walk_meters: int,
    max_walk_meters: int,
) -> bool:
    if first.stop_id and second.stop_id and first.stop_id == second.stop_id:
        return True
    if None not in (first.latitude, first.longitude, second.latitude, second.longitude):
        return walk_meters <= max_walk_meters
    return not (first.stop_id and second.stop_id) and _normalize_stop_name(first.stop_name) == _normalize_stop_name(second.stop_name)


def _transfer_candidate(node: RouteStopNode) -> NearbyStopCandidate:
    return NearbyStopCandidate(
        stopId=node.stop_id,
        stopName=node.stop_name,
        latitude=node.latitude or 0.0,
        longitude=node.longitude or 0.0,
        distanceMeters=0,
        source=FallbackSource.CACHE,
    )


def _transfer_walk_meters(first: RouteStopNode, second: RouteStopNode) -> int:
    if None in (first.latitude, first.longitude, second.latitude, second.longitude):
        return 0
    return _distance_meters(first.latitude, first.longitude, second.latitude, second.longitude)


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
