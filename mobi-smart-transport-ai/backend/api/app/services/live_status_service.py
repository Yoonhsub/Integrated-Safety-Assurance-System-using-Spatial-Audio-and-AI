"""실시간 통합 상태 서비스.

Flutter 추적 패널이 한 번 호출하면 필요한 실시간 정보를 모두 받도록 집계한다.
- 도착정보: TAGO 버스도착정보(get_arrivals_tool)
- 버스 위치: TAGO 버스위치정보(get_bus_locations_tool) + 노선 노드 좌표 매핑
- 운행상태: evaluate_route_service_status
- 보행경로: walking_route_service(TMAP, fallback 직선거리)
- 근처 정류장: nearby_stops_service(청주 정류소 카탈로그 캐시)
과호출을 막기 위해 집계 결과를 짧게(기본 15s) 캐시한다. 혼잡도는 데이터가 없으면
"미제공"으로 두고 절대 임의 생성하지 않는다.
"""
from __future__ import annotations

import os
import time

from app.schemas.v3 import FallbackSource, utc_now
from app.schemas.v3_map import GeoPoint, LiveStatusResponse, NearbyStop
from app.services import nearby_stops_service, walking_route_service
from app.services.route_service_status import evaluate_route_service_status
from app.services.v3_agent_tools import get_arrivals_tool, get_bus_locations_tool

# key -> (expires_at_monotonic, LiveStatusResponse)
_CACHE: dict[tuple, tuple[float, LiveStatusResponse]] = {}


def _cache_ttl_seconds() -> float:
    try:
        return max(0.0, float(os.getenv("LIVE_STATUS_CACHE_TTL_SECONDS", "15")))
    except ValueError:
        return 15.0


def _resolve_live(mode: str | None) -> bool:
    if mode:
        return mode.strip().lower() == "live"
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")


def _board_alight_coords(
    route_no,
    route_id,
    board_stop_id,
    alight_stop_id,
    board_lat,
    board_lng,
    alight_lat,
    alight_lng,
    board_stop_name=None,
    alight_stop_name=None,
    user_lat=None,
    user_lng=None,
):
    """제공된 좌표 우선, 없으면 노선 노드 좌표로 보강한다."""
    from app.api.routes.v3_bus import _node_coordinate, _route_nodes

    board = (board_lat, board_lng) if board_lat is not None and board_lng is not None else None
    alight = (alight_lat, alight_lng) if alight_lat is not None and alight_lng is not None else None
    if board is None or alight is None:
        try:
            nodes = _route_nodes(route_no=route_no, route_id=route_id or "")
        except Exception:
            nodes = {}
        if board is None:
            board = _node_coordinate(nodes.get(board_stop_id))
        if alight is None and alight_stop_id:
            alight = _node_coordinate(nodes.get(alight_stop_id))
    if board is None and board_stop_name:
        match = nearby_stops_service.find_named_stop(
            stop_name=board_stop_name,
            origin_lat=user_lat,
            origin_lng=user_lng,
        )
        if match is not None:
            board = match.latitude, match.longitude
    if alight is None and alight_stop_name:
        match = nearby_stops_service.find_named_stop(stop_name=alight_stop_name)
        if match is not None:
            alight = match.latitude, match.longitude
    return board, alight


def _cache_key(
    route_no,
    route_id,
    board_stop_id,
    alight_stop_id,
    user_lat,
    user_lng,
    board_lat,
    board_lng,
    alight_lat,
    alight_lng,
    dest_lat,
    dest_lng,
    board_stop_name,
    alight_stop_name,
    live,
):
    return (
        route_no,
        route_id or "",
        board_stop_id,
        alight_stop_id or "",
        round(user_lat, 4) if user_lat is not None else None,
        round(user_lng, 4) if user_lng is not None else None,
        round(board_lat, 4) if board_lat is not None else None,
        round(board_lng, 4) if board_lng is not None else None,
        round(alight_lat, 4) if alight_lat is not None else None,
        round(alight_lng, 4) if alight_lng is not None else None,
        round(dest_lat, 4) if dest_lat is not None else None,
        round(dest_lng, 4) if dest_lng is not None else None,
        board_stop_name or "",
        alight_stop_name or "",
        bool(live),
    )


def get_live_status(
    *,
    session_id: str | None,
    route_no: str,
    route_id: str | None,
    board_stop_id: str,
    alight_stop_id: str | None,
    user_lat: float | None,
    user_lng: float | None,
    board_lat: float | None = None,
    board_lng: float | None = None,
    alight_lat: float | None = None,
    alight_lng: float | None = None,
    dest_lat: float | None = None,
    dest_lng: float | None = None,
    board_stop_name: str | None = None,
    alight_stop_name: str | None = None,
    dest_name: str | None = None,
    mode: str | None = None,
) -> LiveStatusResponse:
    live = _resolve_live(mode)
    key = _cache_key(
        route_no,
        route_id,
        board_stop_id,
        alight_stop_id,
        user_lat,
        user_lng,
        board_lat,
        board_lng,
        alight_lat,
        alight_lng,
        dest_lat,
        dest_lng,
        board_stop_name,
        alight_stop_name,
        live,
    )
    now = time.monotonic()
    cached = _CACHE.get(key)
    if cached is not None and cached[0] > now:
        return cached[1]

    warnings: list[str] = []

    # 1) 도착정보
    try:
        arrivals_res = get_arrivals_tool(
            route_id=route_id,
            route_no=route_no,
            stop_id=board_stop_id,
            mode=mode,
            live=live,
        )
        arrivals = [a for a in arrivals_res.arrivals if a.routeNo == route_no or a.routeId == route_id]
        fallback_source = arrivals_res.fallbackSource
        service_status = arrivals_res.serviceStatus or evaluate_route_service_status(
            route_no=route_no, arrivals=arrivals
        )
    except Exception:
        arrivals = []
        fallback_source = FallbackSource.ERROR
        service_status = evaluate_route_service_status(route_no=route_no, arrivals=[])
        warnings.append("도착정보를 확인하지 못했어.")

    # 2) 좌표 보강
    board_coord, alight_coord = _board_alight_coords(
        route_no, route_id, board_stop_id, alight_stop_id,
        board_lat, board_lng, alight_lat, alight_lng,
        board_stop_name, alight_stop_name, user_lat, user_lng,
    )

    # 3) 버스 위치
    bus_positions = []
    if live and route_id:
        try:
            from app.api.routes.v3_bus import _node_coordinate, _route_nodes
            from app.schemas.v3 import V3BusPosition

            nodes = _route_nodes(route_no=route_no, route_id=route_id)
            locations = get_bus_locations_tool(route_id=route_id, route_no=route_no, mode=mode).locations
            for loc in locations:
                coord = _node_coordinate(nodes.get(loc.nodeId))
                bus_positions.append(
                    V3BusPosition(
                        busId=loc.vehicleno or None,
                        routeNo=route_no,
                        routeId=route_id,
                        nodeId=loc.nodeId or None,
                        nodeName=loc.nodeNm or None,
                        latitude=coord[0] if coord else None,
                        longitude=coord[1] if coord else None,
                    )
                )
        except Exception:
            warnings.append("현재 버스 위치 조회에 실패했어.")
    if not bus_positions:
        warnings.append("현재 버스 위치는 아직 조회되지 않았어.")

    # 4) 보행경로(현재 위치 -> 승차 정류장)
    walking = None
    if user_lat is not None and user_lng is not None and board_coord is not None:
        walking = walking_route_service.get_walking_route(
            origin_lat=user_lat,
            origin_lng=user_lng,
            dest_lat=board_coord[0],
            dest_lng=board_coord[1],
            dest_name="승차 정류장",
            live=live,
        )
    elif user_lat is None or user_lng is None:
        warnings.append("현재 위치가 없어 보행경로를 계산하지 못했어.")

    # 5) 하차 정류장 -> 목적지 보행경로
    egress_walking = None
    if alight_coord is not None and dest_lat is not None and dest_lng is not None:
        egress_walking = walking_route_service.get_walking_route(
            origin_lat=alight_coord[0],
            origin_lng=alight_coord[1],
            dest_lat=dest_lat,
            dest_lng=dest_lng,
            dest_name=dest_name or "목적지",
            live=live,
        )

    # 6) 근처 정류장
    nearby = []
    if user_lat is not None and user_lng is not None:
        nearby = nearby_stops_service.find_nearby_stops(
            lat=user_lat, lng=user_lng, radius_meters=500, limit=5
        ).stops

    # 7) 선택 정류장 표현
    selected_board = None
    if board_coord is not None:
        selected_board = NearbyStop(
            stopId=board_stop_id,
            stopName=board_stop_name or next((s.stopName for s in nearby if s.stopId == board_stop_id), "승차 정류장"),
            latitude=board_coord[0],
            longitude=board_coord[1],
            distanceMeters=0.0,
            source="ROUTE",
        )
    selected_alight = None
    if alight_coord is not None and alight_stop_id:
        selected_alight = NearbyStop(
            stopId=alight_stop_id,
            stopName=alight_stop_name or "하차 정류장",
            latitude=alight_coord[0],
            longitude=alight_coord[1],
            distanceMeters=0.0,
            source="ROUTE",
        )

    # 8) 혼잡도(데이터 없으면 미제공, 임의 생성 금지)
    congestion = "미제공"
    for arrival in arrivals:
        if arrival.congestion:
            congestion = arrival.congestion
            break

    user_location = (
        GeoPoint(latitude=user_lat, longitude=user_lng)
        if user_lat is not None and user_lng is not None
        else None
    )

    response = LiveStatusResponse(
        sessionId=session_id,
        routeNo=route_no,
        routeId=route_id,
        userLocation=user_location,
        nearbyStops=nearby,
        selectedBoardStop=selected_board,
        selectedAlightStop=selected_alight,
        walkingRouteToBoardStop=walking,
        walkingRouteFromAlightStop=egress_walking,
        arrivals=arrivals,
        busPositions=bus_positions,
        serviceStatus=service_status,
        congestion=congestion,
        lastUpdatedAt=utc_now(),
        nextRefreshSeconds=30,
        warnings=list(dict.fromkeys(warnings)),
        fallbackSource=fallback_source,
    )

    ttl = _cache_ttl_seconds()
    if ttl > 0:
        _CACHE[key] = (now + ttl, response)
    return response
