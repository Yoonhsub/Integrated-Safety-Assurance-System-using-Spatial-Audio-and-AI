from __future__ import annotations

from dataclasses import dataclass, replace
from threading import Lock
from typing import Iterable, Sequence

from app.schemas.v3 import FallbackSource
from services.public_data.public_data_client import BusRouteService


@dataclass(frozen=True)
class RouteStopNode:
    stop_id: str
    stop_name: str
    order: int
    latitude: float | None = None
    longitude: float | None = None


@dataclass(frozen=True)
class RouteSequence:
    route_id: str
    route_no: str
    nodes: tuple[RouteStopNode, ...]
    source: FallbackSource = FallbackSource.MOCK


class RouteStopSequenceCache:
    """Caches ordered route nodes and the reverse indexes used by route planners."""

    def __init__(
        self,
        *,
        route_service: BusRouteService | None = None,
        city_code: str = "33010",
        mock_sequences: Sequence[RouteSequence] = (),
    ) -> None:
        self._route_service = route_service or BusRouteService()
        self._city_code = city_code
        self._mock_route_ids: set[str] = set()
        self._sequences_by_route_id: dict[str, RouteSequence] = {}
        self._route_ids_by_no: dict[str, set[str]] = {}
        self._route_ids_by_node: dict[str, set[str]] = {}
        self._loaded_live_route_nos: set[str] = set()
        self._lock = Lock()
        self._load_lock = Lock()
        for sequence in mock_sequences:
            normalized = self.register_sequence(sequence)
            self._mock_route_ids.add(normalized.route_id)

    def register_sequence(self, sequence: RouteSequence) -> RouteSequence:
        nodes = tuple(sorted(sequence.nodes, key=lambda node: node.order))
        normalized = replace(sequence, nodes=nodes)
        with self._lock:
            previous = self._sequences_by_route_id.get(sequence.route_id)
            if previous is not None:
                self._remove_indexes(previous)
            self._sequences_by_route_id[normalized.route_id] = normalized
            self._route_ids_by_no.setdefault(normalized.route_no, set()).add(normalized.route_id)
            for node in normalized.nodes:
                if node.stop_id:
                    self._route_ids_by_node.setdefault(node.stop_id, set()).add(normalized.route_id)
        return normalized

    def clear_live(self) -> None:
        with self._lock:
            live_ids = set(self._sequences_by_route_id) - self._mock_route_ids
            for route_id in live_ids:
                sequence = self._sequences_by_route_id.pop(route_id)
                self._remove_indexes(sequence)
            self._loaded_live_route_nos.clear()

    def sequences(self, *, live: bool, route_nos: Iterable[str] = ()) -> list[RouteSequence]:
        requested = {route_no.strip() for route_no in route_nos if route_no.strip()}
        if live and requested:
            self.load_live_routes(requested)
            live_sequences = [
                sequence
                for sequence in self._sequences_by_route_id.values()
                if sequence.route_no in requested and sequence.source == FallbackSource.PUBLIC_API
            ]
            if live_sequences:
                return sorted(live_sequences, key=lambda sequence: (sequence.route_no, sequence.route_id))

        mock_sequences = [
            self._sequences_by_route_id[route_id]
            for route_id in self._mock_route_ids
            if route_id in self._sequences_by_route_id
        ]
        return sorted(mock_sequences, key=lambda sequence: (sequence.route_no, sequence.route_id))

    def load_live_routes(self, route_nos: Iterable[str]) -> None:
        with self._load_lock:
            self._load_live_routes(route_nos)

    def _load_live_routes(self, route_nos: Iterable[str]) -> None:
        for route_no in sorted({value.strip() for value in route_nos if value.strip()}):
            if route_no in self._loaded_live_route_nos:
                continue
            try:
                resolve_many = getattr(self._route_service, "resolve_route_ids", None)
                resolved_route_ids = (
                    resolve_many(self._city_code, route_no)
                    if callable(resolve_many)
                    else [self._route_service.resolve_route_id(self._city_code, route_no)]
                )
            except Exception:
                self._loaded_live_route_nos.add(route_no)
                continue
            for resolved_route_id in resolved_route_ids:
                if not resolved_route_id:
                    continue
                try:
                    route_stops = self._route_service.get_route_stops(self._city_code, resolved_route_id)
                except Exception:
                    continue
                grouped: dict[str, list[RouteStopNode]] = {}
                for index, stop in enumerate(route_stops.nodes, start=1):
                    route_id = str(route_stops.routeId or resolved_route_id)
                    grouped.setdefault(route_id, []).append(
                        RouteStopNode(
                            stop_id=str(stop.nodeId or ""),
                            stop_name=str(stop.nodeNm or ""),
                            order=int(stop.nodeOrd or index),
                        )
                    )
                for route_id, nodes in grouped.items():
                    if nodes:
                        self.register_sequence(
                            RouteSequence(
                                route_id=route_id,
                                route_no=route_no,
                                nodes=tuple(nodes),
                                source=FallbackSource.PUBLIC_API,
                            )
                        )
            self._loaded_live_route_nos.add(route_no)

    def sequence_for_route(self, route_id: str) -> RouteSequence | None:
        return self._sequences_by_route_id.get(route_id)

    def route_ids_for_route_no(self, route_no: str) -> set[str]:
        return set(self._route_ids_by_no.get(route_no, set()))

    def route_ids_for_stop(self, node_id: str) -> set[str]:
        return set(self._route_ids_by_node.get(node_id, set()))

    def common_route_ids(self, boarding_node_id: str, alighting_node_id: str) -> set[str]:
        return self.route_ids_for_stop(boarding_node_id) & self.route_ids_for_stop(alighting_node_id)

    def can_travel(self, route_id: str, boarding_node_id: str, alighting_node_id: str) -> bool:
        sequence = self.sequence_for_route(route_id)
        if sequence is None:
            return False
        board_orders = [node.order for node in sequence.nodes if node.stop_id == boarding_node_id]
        alight_orders = [node.order for node in sequence.nodes if node.stop_id == alighting_node_id]
        return any(board < alight for board in board_orders for alight in alight_orders)

    def _remove_indexes(self, sequence: RouteSequence) -> None:
        route_ids = self._route_ids_by_no.get(sequence.route_no)
        if route_ids is not None:
            route_ids.discard(sequence.route_id)
            if not route_ids:
                self._route_ids_by_no.pop(sequence.route_no, None)
        for node in sequence.nodes:
            route_ids = self._route_ids_by_node.get(node.stop_id)
            if route_ids is None:
                continue
            route_ids.discard(sequence.route_id)
            if not route_ids:
                self._route_ids_by_node.pop(node.stop_id, None)
