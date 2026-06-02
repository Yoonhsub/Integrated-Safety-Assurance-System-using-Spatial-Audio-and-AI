"""청주 목적지 카탈로그와 실시간 ID 해석.

V3 데모는 사람이 읽는 (목적지 → 노선번호 + 정류소명) 카탈로그만 유지하고,
실제 TAGO ``routeId``/``nodeId``는 호출 시점에 ``BusRouteService``로 해석한다.
이렇게 하면 라이브 모드에서 더 이상 ``mock-route-502`` 같은 가짜 ID를 공공 API에
먹여 빈 응답을 받는 일이 없다.

- live=True  : 노선번호 → ``getRouteNoList`` → routeId, 그 노선의 경유 정류소에서
               정류소명 매칭 → nodeId. 결과는 프로세스 내 캐시.
- live=False : 기존 데모용 mock ID를 그대로 사용(안정적인 busId 시나리오 보존).
"""

from __future__ import annotations

import threading
from dataclasses import dataclass

from services.public_data.public_data_client import BusRouteService

CHEONGJU_CITY_CODE = "33010"

# 목적지(정규화 명) → 사람이 읽는 노선/정류소. 가짜 ID 없음.
_CATALOG: dict[str, dict[str, str]] = {
    "사창사거리": {"routeNo": "502", "stopName": "사창사거리"},
    "충북대병원": {"routeNo": "823", "stopName": "충북대학교병원"},
    "청주고속버스터미널": {"routeNo": "502", "stopName": "고속버스터미널"},
    "상당구청": {"routeNo": "862", "stopName": "상당구청"},
}

# mock 모드 전용 ID. 데모 시나리오의 안정적인 busId(BUS_2 등)가 이 stopId에 묶여 있다.
_MOCK_IDS: dict[str, dict[str, str]] = {
    "사창사거리": {"routeId": "mock-route-502", "stopId": "mock-stop-001", "stopName": "사창사거리 정류장"},
    "충북대병원": {"routeId": "mock-route-823", "stopId": "mock-stop-002", "stopName": "충북대학교병원 정류장"},
    "청주고속버스터미널": {"routeId": "mock-route-502", "stopId": "mock-stop-003", "stopName": "청주고속버스터미널 정류장"},
    "상당구청": {"routeId": "mock-route-862", "stopId": "mock-stop-004", "stopName": "상당구청 정류장"},
}

_CONFIDENCE: dict[str, float] = {
    "사창사거리": 0.95,
    "충북대병원": 0.9,
    "청주고속버스터미널": 0.88,
    "상당구청": 0.95,
}

DESTINATIONS: tuple[str, ...] = tuple(_CATALOG.keys())


@dataclass(frozen=True)
class ResolvedRoute:
    destination: str
    routeNo: str
    routeId: str
    stopId: str
    stopName: str
    confidence: float
    source: str  # "PUBLIC_API" | "MOCK"


_live_cache: dict[str, ResolvedRoute] = {}
_lock = threading.Lock()


def is_known_destination(destination: str) -> bool:
    return destination in _CATALOG


def resolve(
    destination: str,
    *,
    live: bool,
    route_service: BusRouteService | None = None,
) -> ResolvedRoute | None:
    """목적지를 ``ResolvedRoute``로 해석한다. 알 수 없는 목적지면 ``None``.

    라이브 해석이 실패(키 오류/네트워크/매칭 실패)하면 ``None``을 반환하므로,
    호출자는 데모 흐름이 끊기지 않도록 ``live=False`` 폴백을 시도할 수 있다.
    """
    if destination not in _CATALOG:
        return None

    if not live:
        return _mock_resolved(destination)

    with _lock:
        cached = _live_cache.get(destination)
    if cached is not None:
        return cached

    resolved = _resolve_live(destination, route_service or BusRouteService())
    if resolved is None:
        return None

    with _lock:
        _live_cache[destination] = resolved
    return resolved


def resolve_or_mock(destination: str, *, live: bool) -> ResolvedRoute | None:
    """live 해석을 우선 시도하고, 실패하면 mock으로 폴백한다."""
    resolved = resolve(destination, live=live)
    if resolved is None and live:
        return _mock_resolved(destination)
    return resolved


def _mock_resolved(destination: str) -> ResolvedRoute | None:
    if destination not in _CATALOG:
        return None
    mock = _MOCK_IDS[destination]
    catalog = _CATALOG[destination]
    return ResolvedRoute(
        destination=destination,
        routeNo=catalog["routeNo"],
        routeId=mock["routeId"],
        stopId=mock["stopId"],
        stopName=mock["stopName"],
        confidence=_CONFIDENCE.get(destination, 0.85),
        source="MOCK",
    )


def _resolve_live(destination: str, service: BusRouteService) -> ResolvedRoute | None:
    catalog = _CATALOG[destination]
    try:
        route_id = service.resolve_route_id(CHEONGJU_CITY_CODE, catalog["routeNo"])
        if not route_id:
            return None
        stops = service.get_route_stops(CHEONGJU_CITY_CODE, route_id)
    except Exception:
        return None

    node = _match_stop(stops.nodes, catalog["stopName"])
    if node is None:
        return None

    return ResolvedRoute(
        destination=destination,
        routeNo=catalog["routeNo"],
        routeId=route_id,
        stopId=node.nodeId,
        stopName=node.nodeNm,
        confidence=_CONFIDENCE.get(destination, 0.85),
        source="PUBLIC_API",
    )


def _match_stop(nodes, stop_name: str):
    target = stop_name.replace(" ", "")
    exact = [node for node in nodes if node.nodeNm.replace(" ", "") == target]
    if exact:
        return exact[0]
    partial = [node for node in nodes if target in node.nodeNm.replace(" ", "")]
    return partial[0] if partial else None


def clear_cache() -> None:
    """테스트/모드 전환 시 해석 캐시를 비운다."""
    with _lock:
        _live_cache.clear()
