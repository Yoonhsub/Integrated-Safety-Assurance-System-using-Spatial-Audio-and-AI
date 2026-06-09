from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, HTTPException, Query

from app.schemas.bus_info import BusArrivalsResponse
from app.schemas.v3 import (
    DestinationResolveResponse,
    FallbackSource,
    PublicBusStopEvidence,
    RouteRecommendation,
    RoutePlanRequest,
    RouteRecommendResponse,
    RoutePlanningEvidence,
    RoutePlanResponse,
    V3BusPosition,
    V3BusArrival,
    V3BusArrivalsResponse,
    V3LiveRouteMarker,
    V3LiveRouteStatusResponse,
    utc_now,
)
import os

from services.public_data.public_data_client import BusArrivalsService, BusLocationService

from app.services import cheongju_route_catalog
from app.services.bus_info_gateway_service import BusInfoGatewayResult, BusInfoGatewayService
from app.services.cheongju_bus_stops_service import CheongjuBusStopsService
from app.services.cheongju_route_planner import _mock_route_sequences
from app.services.destination_candidate_resolver import DestinationCandidateResolver
from app.services.route_service_status import evaluate_route_service_status
from app.services.route_stop_sequence_cache import RouteStopNode
from app.services.transit_planner_orchestrator import TransitPlannerOrchestrator
from app.services.v3_gemini_service import generate_route_plan_summary, set_nlu_provider

router = APIRouter()
_service = BusInfoGatewayService()
_stop_catalog = CheongjuBusStopsService()
_destination_resolver = DestinationCandidateResolver(stop_catalog=_stop_catalog)
DataMode = Literal["mock", "live"]

def _is_live_mode() -> bool:
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")


def _resolve_live(mode: DataMode | None) -> bool:
    """요청별 mode가 오면 우선 적용하고, 없으면 전역 env로 폴백한다.

    'API 데이터 테스트' 화면은 항상 mode='live'를 보내므로, 전역 토글 상태나
    서버 재시작과 무관하게 해당 요청은 반드시 실데이터 경로를 탄다.
    """
    if mode:
        return mode == "live"
    return _is_live_mode()


def _gateway_for(live: bool) -> BusInfoGatewayService:
    """요청별 모드를 강제한 게이트웨이. 전역 env와 무관하게 mock/live를 고정한다."""
    return BusInfoGatewayService(public_data_service=BusArrivalsService(use_mock=not live))


def _gateway_for_request(*, live: bool, mode: DataMode | None) -> BusInfoGatewayService:
    """mode 파라미터가 있을 때만 강제 gateway를 만들고, 없으면 주입 가능한 기본 gateway를 쓴다."""
    if mode is None:
        return _service
    return _gateway_for(live)


def _key(value: str) -> str:
    return "".join(value.strip().split()).lower()


# 별칭(STT 변형 포함) → 카탈로그 정규 목적지명. 실제 routeId/nodeId는
# cheongju_route_catalog가 라이브 모드에서 런타임 해석한다.
_DESTINATION_ALIASES: dict[str, str] = {
    _key("사창사거리"): "사창사거리",
    _key("사창 사거리"): "사창사거리",
    _key("사직사거리"): "사창사거리",  # common speech/STT correction path for the demo
    _key("사창"): "사창사거리",
    _key("충북대병원"): "충북대병원",
    _key("충북대학교병원"): "충북대병원",
    _key("충북대학교 병원"): "충북대병원",
    _key("충대병원"): "충북대병원",
    _key("청주고속버스터미널"): "청주고속버스터미널",
    _key("청주 고속버스터미널"): "청주고속버스터미널",
    _key("고속버스터미널"): "청주고속버스터미널",
    _key("청주터미널"): "청주고속버스터미널",
    _key("터미널"): "청주고속버스터미널",
}


def _recommendation_for(destination: str, *, live: bool) -> RouteRecommendation | None:
    resolved = cheongju_route_catalog.resolve_or_mock(destination, live=live)
    if resolved is None:
        return None
    return RouteRecommendation(
        destination=resolved.destination,
        stopId=resolved.stopId,
        stopName=resolved.stopName,
        routeNo=resolved.routeNo,
        routeId=resolved.routeId,
        confidence=resolved.confidence,
        fallbackSource=FallbackSource(resolved.source),
    )


def _all_recommendations(*, live: bool) -> list[RouteRecommendation]:
    out: list[RouteRecommendation] = []
    for destination in cheongju_route_catalog.DESTINATIONS:
        recommendation = _recommendation_for(destination, live=live)
        if recommendation is not None:
            out.append(recommendation)
    return out

# V3 demo catalog. These are deterministic mock arrivals for the voice-guidance
# demo only. Congestion is intentionally None unless it comes from a real/cache
# normalized source; the backend must not invent crowding information.
_MOCK_ARRIVALS_BY_STOP: dict[str, list[V3BusArrival]] = {
    "mock-stop-001": [
        V3BusArrival(
            busId="BUS_2",
            routeNo="502",
            routeId="mock-route-502",
            stopId="mock-stop-001",
            arrivalMinutes=6,
            remainingStops=2,
            lowFloor=True,
            congestion=None,
        ),
        V3BusArrival(
            busId="BUS_502_NEXT",
            routeNo="502",
            routeId="mock-route-502",
            stopId="mock-stop-001",
            arrivalMinutes=13,
            remainingStops=6,
            lowFloor=True,
            congestion=None,
        ),
        V3BusArrival(
            busId="BUS_511",
            routeNo="511",
            routeId="mock-route-511",
            stopId="mock-stop-001",
            arrivalMinutes=5,
            remainingStops=1,
            lowFloor=None,
            congestion=None,
        ),
        V3BusArrival(
            busId="BUS_862",
            routeNo="862",
            routeId="mock-route-862-to-fortress",
            stopId="mock-stop-001",
            arrivalMinutes=11,
            remainingStops=5,
            lowFloor=True,
            congestion=None,
        ),
    ],
    "mock-stop-002": [
        V3BusArrival(
            busId="BUS_823",
            routeNo="823",
            routeId="mock-route-823",
            stopId="mock-stop-002",
            arrivalMinutes=8,
            remainingStops=3,
            lowFloor=True,
            congestion=None,
        )
    ],
    "mock-stop-003": [
        V3BusArrival(
            busId="BUS_502_TERMINAL",
            routeNo="502",
            routeId="mock-route-502",
            stopId="mock-stop-003",
            arrivalMinutes=9,
            remainingStops=4,
            lowFloor=True,
            congestion=None,
        )
    ],
    "mock-stop-004": [
        V3BusArrival(
            busId="BUS_862_SANGDANG",
            routeNo="862",
            routeId="mock-route-862",
            stopId="mock-stop-004",
            arrivalMinutes=7,
            remainingStops=3,
            lowFloor=True,
            congestion=None,
        )
    ],
}


@router.get("/destination-candidates", response_model=DestinationResolveResponse)
def destination_candidates(
    q: str = Query(min_length=1),
    originLat: float | None = Query(default=None, ge=-90, le=90),
    originLng: float | None = Query(default=None, ge=-180, le=180),
    mode: DataMode | None = Query(default=None),
) -> DestinationResolveResponse:
    """장소명/주소/정류장명 발화를 목적지 후보와 주변 정류장 후보로 해석한다."""
    _validate_origin_pair(originLat, originLng)
    return _destination_resolver.resolve(
        heard_text=q,
        origin_lat=originLat,
        origin_lng=originLng,
        live=_resolve_live(mode),
    )


@router.get("/route-plan", response_model=RoutePlanResponse)
def route_plan(
    q: str = Query(min_length=1),
    originLat: float | None = Query(default=None, ge=-90, le=90),
    originLng: float | None = Query(default=None, ge=-180, le=180),
    mode: DataMode | None = Query(default=None),
) -> RoutePlanResponse:
    """목적지 발화와 현재 위치를 기반으로 직통/1회 환승 RoutePlan 후보를 계산한다."""
    return _build_route_plan(q=q, origin_lat=originLat, origin_lng=originLng, mode=mode)


@router.post("/route-plan", response_model=RoutePlanResponse)
def route_plan_post(payload: RoutePlanRequest) -> RoutePlanResponse:
    """Flutter/agent clients can send the same RoutePlan request as JSON."""
    return _build_route_plan(
        q=payload.destinationText,
        origin_lat=payload.originLat,
        origin_lng=payload.originLng,
        mode=payload.mode,
    )


def _build_route_plan(
    *,
    q: str,
    origin_lat: float | None,
    origin_lng: float | None,
    mode: DataMode | None,
) -> RoutePlanResponse:
    _validate_origin_pair(origin_lat, origin_lng)
    live = _resolve_live(mode)
    arrivals_by_route: dict[tuple[str, str, str], V3BusArrivalsResponse] = {}

    def fetch_arrivals(stop_id: str, route_no: str | None, route_id: str | None) -> V3BusArrivalsResponse:
        key = (stop_id.strip(), route_no or "", route_id or "")
        if key not in arrivals_by_route:
            arrivals_by_route[key] = _route_plan_arrivals(
                stop_id,
                route_no=route_no,
                route_id=route_id,
                live=live,
                mode=mode,
            )
        return arrivals_by_route[key]

    planner = TransitPlannerOrchestrator(
        resolver=_destination_resolver,
        arrival_fetcher=fetch_arrivals,
    )
    return planner.plan(
        heard_text=q,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
        live=live,
    )


@router.get("/route-recommend", response_model=RouteRecommendResponse)
def route_recommend(
    destination: str = Query(min_length=1),
    originLat: float | None = Query(default=None, ge=-90, le=90),
    originLng: float | None = Query(default=None, ge=-180, le=180),
    mode: DataMode | None = Query(default=None),
    nluProvider: Literal["auto", "gemini", "openai"] = Query(default="auto"),
) -> RouteRecommendResponse:
    # 경로 요약·위치 그라운딩에 쓸 제공자(Gemini/GPT) 설정 — converse 토글과 일관.
    set_nlu_provider(nluProvider)
    _validate_origin_pair(originLat, originLng)
    live = _resolve_live(mode)
    canonical = _DESTINATION_ALIASES.get(_key(destination))
    recommendation = _recommendation_for(canonical, live=live) if canonical else None
    if recommendation is None:
        raise HTTPException(
            status_code=404,
            detail={
                "error": {
                    "code": "UNKNOWN_DESTINATION",
                    "message": "No route recommendation is registered for the destination.",
                    "detail": {"destination": destination},
                }
            },
        )
    # 정류소 위치 증빙과 도착 증빙은 GPS 좌표가 없어도 공공 API로 조회한다.
    # 웹에서 위치 권한이 없을 때도 증빙 카드가 0,0/0건으로 비지 않게 하기 위함.
    stop_evidence = _public_stop_evidence(
        recommendation,
        origin_lat=originLat,
        origin_lng=originLng,
    )
    planning_data_source, evidence = _planning_evidence(recommendation, live=live)

    # Google Maps 기반 위치 관계 요약은 현재 좌표가 있어야만 의미가 있다.
    planning_result = None
    if originLat is not None and originLng is not None:
        planning_result = generate_route_plan_summary(
            destination=recommendation.destination,
            stop_name=recommendation.stopName,
            origin_lat=originLat,
            origin_lng=originLng,
            validated_candidates=[
                (
                    f"{item.destination}: {item.stopName}, {item.routeNo}번, "
                    f"routeId={item.routeId}, confidence={item.confidence}"
                )
                for item in _all_recommendations(live=live)
            ],
            arrival_context=_planning_arrival_context(evidence.arrivals),
            arrival_source=planning_data_source.value,
            public_stop_context=_public_stop_context(stop_evidence),
        )

    return RouteRecommendResponse(
        recommendations=[recommendation],
        fallbackSource=planning_data_source or FallbackSource.ERROR,
        usedGemini=planning_result is not None,
        planningModel=planning_result[0] if planning_result else None,
        planningSummary=planning_result[1] if planning_result else None,
        planningDataSource=planning_data_source,
        mapsGrounded=bool(planning_result[2]) if planning_result else False,
        mapsEvidence=planning_result[2] if planning_result else [],
        stopEvidence=stop_evidence,
        evidence=evidence,
    )


@router.get("/arrivals", response_model=V3BusArrivalsResponse)
def arrivals(
    stopId: str = Query(min_length=1, pattern=r"\S"),
    routeNo: str | None = None,
    mode: DataMode | None = Query(default=None),
) -> V3BusArrivalsResponse:
    normalized_stop_id = stopId.strip()
    live = _resolve_live(mode)

    # Cache/live public data must win over the local V3 mock catalog when present,
    # because it represents fresher or externally supplied information.
    try:
        gateway_result = _gateway_for_request(live=live, mode=mode).get_arrivals_with_source(normalized_stop_id)
    except HTTPException:
        # live 호출 실패/키 누락도 데모 정류장은 로컬 V3 mock으로 graceful fallback한다.
        mock = _mock_response(normalized_stop_id, route_no=routeNo)
        if mock is not None:
            return mock
        return _arrivals_response(
            stopId=normalized_stop_id,
            routeNo=routeNo,
            arrivals=[],
            fallbackSource=FallbackSource.ERROR,
        )

    if gateway_result.source == "CACHE":
        return _from_gateway_response(gateway_result.response, route_no=routeNo, fallback_source=FallbackSource.CACHE)
    if gateway_result.source == "PUBLIC_API":
        return _from_gateway_response(
            gateway_result.response,
            route_no=routeNo,
            fallback_source=FallbackSource.PUBLIC_API,
        )

    # public_data mock is generic. For the V3 guided demo stops, use the richer
    # catalog that carries stable busId values such as BUS_2.
    mock = _mock_response(normalized_stop_id, route_no=routeNo)
    if mock is not None:
        return mock
    return _from_gateway_response(gateway_result.response, route_no=routeNo, fallback_source=FallbackSource.MOCK)


@router.get("/live-route-status", response_model=V3LiveRouteStatusResponse)
def live_route_status(
    routeNo: str = Query(min_length=1, pattern=r"\S"),
    routeId: str = Query(min_length=1, pattern=r"\S"),
    boardStopId: str = Query(min_length=1, pattern=r"\S"),
    alightStopId: str = Query(min_length=1, pattern=r"\S"),
    userLat: float | None = Query(default=None, ge=-90, le=90),
    userLng: float | None = Query(default=None, ge=-180, le=180),
    boardLat: float | None = Query(default=None, ge=-90, le=90),
    boardLng: float | None = Query(default=None, ge=-180, le=180),
    alightLat: float | None = Query(default=None, ge=-90, le=90),
    alightLng: float | None = Query(default=None, ge=-180, le=180),
    mode: DataMode | None = Query(default=None),
) -> V3LiveRouteStatusResponse:
    """Return panel-ready route data without fabricating unavailable positions."""

    _validate_origin_pair(userLat, userLng)
    _validate_origin_pair(boardLat, boardLng)
    _validate_origin_pair(alightLat, alightLng)
    live = _resolve_live(mode)
    arrivals_response = _route_plan_arrivals(
        boardStopId,
        route_no=routeNo,
        route_id=routeId,
        live=live,
        mode=mode,
    )
    service_status = arrivals_response.serviceStatus or evaluate_route_service_status(
        route_no=routeNo,
        arrivals=arrivals_response.arrivals,
    )
    route_nodes = _route_nodes(route_no=routeNo, route_id=routeId)
    board_node = route_nodes.get(boardStopId)
    alight_node = route_nodes.get(alightStopId)
    resolved_board = _coordinate_pair(boardLat, boardLng) or _node_coordinate(board_node)
    resolved_alight = _coordinate_pair(alightLat, alightLng) or _node_coordinate(alight_node)

    markers: list[V3LiveRouteMarker] = []
    if userLat is not None and userLng is not None:
        markers.append(V3LiveRouteMarker(type="USER", label="내 현재 위치", latitude=userLat, longitude=userLng))
    if resolved_board is not None:
        markers.append(V3LiveRouteMarker(type="BOARD_STOP", label="승차 정류장", latitude=resolved_board[0], longitude=resolved_board[1]))
    if resolved_alight is not None:
        markers.append(V3LiveRouteMarker(type="ALIGHT_STOP", label="하차 정류장", latitude=resolved_alight[0], longitude=resolved_alight[1]))
        markers.append(V3LiveRouteMarker(type="DESTINATION", label="목적지 근처", latitude=resolved_alight[0], longitude=resolved_alight[1]))

    warnings: list[str] = []
    bus_positions: list[V3BusPosition] = []
    if live:
        try:
            locations = BusLocationService().get_locations("33010", routeId).locations
        except Exception:
            locations = []
        for location in locations:
            node = route_nodes.get(location.nodeId)
            coordinate = _node_coordinate(node)
            position = V3BusPosition(
                busId=location.vehicleno or None,
                routeNo=routeNo,
                routeId=routeId,
                nodeId=location.nodeId or None,
                nodeName=location.nodeNm or None,
                latitude=coordinate[0] if coordinate else None,
                longitude=coordinate[1] if coordinate else None,
            )
            bus_positions.append(position)
            if coordinate is not None:
                markers.append(
                    V3LiveRouteMarker(
                        type="BUS",
                        label=f"{routeNo}번 버스",
                        latitude=coordinate[0],
                        longitude=coordinate[1],
                        busId=position.busId,
                    )
                )
    if not bus_positions:
        warnings.append("현재 버스 위치는 아직 조회되지 않았습니다.")
    if resolved_board is None or resolved_alight is None:
        warnings.append("일부 정류장 좌표를 확인하지 못했어요.")

    return V3LiveRouteStatusResponse(
        routeNo=routeNo,
        routeId=routeId,
        boardStopId=boardStopId,
        alightStopId=alightStopId,
        markers=markers,
        arrivals=arrivals_response.arrivals,
        busPositions=bus_positions,
        serviceStatus=service_status,
        warnings=list(dict.fromkeys(warnings)),
        updatedAt=utc_now(),
        fallbackSource=arrivals_response.fallbackSource,
    )


def _route_nodes(*, route_no: str, route_id: str) -> dict[str, RouteStopNode]:
    sequences = _mock_route_sequences()
    selected = next((sequence for sequence in sequences if sequence.route_id == route_id), None)
    if selected is None:
        selected = next((sequence for sequence in sequences if sequence.route_no == route_no), None)
    if selected is None:
        return {}
    return {node.stop_id: node for node in selected.nodes}


def _coordinate_pair(
    latitude: float | None,
    longitude: float | None,
) -> tuple[float, float] | None:
    if latitude is None or longitude is None:
        return None
    return latitude, longitude


def _node_coordinate(node: RouteStopNode | None) -> tuple[float, float] | None:
    if node is None or node.latitude is None or node.longitude is None:
        return None
    return node.latitude, node.longitude


def _route_plan_arrivals(
    stop_id: str,
    *,
    route_no: str | None,
    route_id: str | None = None,
    live: bool,
    mode: DataMode | None,
) -> V3BusArrivalsResponse:
    normalized_stop_id = stop_id.strip()
    try:
        gateway_result = _gateway_for_request(live=live, mode=mode).get_arrivals_with_source(normalized_stop_id)
    except HTTPException:
        mock = _mock_response(normalized_stop_id, route_no=route_no, route_id=route_id)
        if mock is not None:
            return mock
        return _arrivals_response(
            stopId=normalized_stop_id,
            routeNo=route_no,
            arrivals=[],
            fallbackSource=FallbackSource.ERROR,
        )

    if gateway_result.source == "CACHE":
        return _from_gateway_response(gateway_result.response, route_no=route_no, route_id=route_id, fallback_source=FallbackSource.CACHE)
    if gateway_result.source == "PUBLIC_API":
        return _from_gateway_response(gateway_result.response, route_no=route_no, route_id=route_id, fallback_source=FallbackSource.PUBLIC_API)

    mock = _mock_response(normalized_stop_id, route_no=route_no, route_id=route_id)
    if mock is not None:
        return mock
    return _from_gateway_response(gateway_result.response, route_no=route_no, route_id=route_id, fallback_source=FallbackSource.MOCK)


def _mock_response(
    stop_id: str,
    *,
    route_no: str | None,
    route_id: str | None = None,
) -> V3BusArrivalsResponse | None:
    catalog = _MOCK_ARRIVALS_BY_STOP.get(stop_id)
    if catalog is None:
        return None
    arrivals = _filter_by_route(catalog, route_no, route_id=route_id)
    return _arrivals_response(
        stopId=stop_id,
        routeNo=route_no,
        arrivals=arrivals,
        fallbackSource=FallbackSource.MOCK,
    )


def _planning_evidence(
    recommendation: RouteRecommendation,
    *,
    live: bool,
) -> tuple[FallbackSource, RoutePlanningEvidence]:
    try:
        gateway_result = _gateway_for(live).get_arrivals_with_source(recommendation.stopId)
    except HTTPException:
        gateway_result = None

    if gateway_result is not None and gateway_result.source in {"CACHE", "PUBLIC_API"}:
        source = FallbackSource(gateway_result.source)
        arrivals = [
            V3BusArrival(
                busId=None,
                routeNo=item.busNo,
                routeId=item.routeId,
                stopId=gateway_result.response.stopId,
                arrivalMinutes=item.arrivalMinutes,
                arrivalSeconds=item.arrivalSeconds,
                remainingStops=item.remainingStops,
                lowFloor=item.lowFloor,
                congestion=item.congestion.value if item.congestion else None,
            )
            for item in gateway_result.response.arrivals
            if item.busNo == recommendation.routeNo or item.routeId == recommendation.routeId
        ]
        return source, RoutePlanningEvidence(
            source=source,
            stopId=recommendation.stopId,
            stopName=recommendation.stopName,
            routeNo=recommendation.routeNo,
            arrivals=arrivals,
        )

    if not live:
        mock_response = _mock_response(recommendation.stopId, route_no=recommendation.routeNo)
        if mock_response is not None:
            return FallbackSource.MOCK, RoutePlanningEvidence(
                source=FallbackSource.MOCK,
                stopId=recommendation.stopId,
                stopName=recommendation.stopName,
                routeNo=recommendation.routeNo,
                arrivals=mock_response.arrivals,
            )
            
    return FallbackSource.ERROR, RoutePlanningEvidence(
        source=FallbackSource.ERROR,
        stopId=recommendation.stopId,
        stopName=recommendation.stopName,
        routeNo=recommendation.routeNo,
        arrivals=[],
    )


def _planning_arrival_context(arrivals: list[V3BusArrival]) -> list[str]:
    return [
        (
            f"{item.routeNo}번: {item.arrivalMinutes}분 뒤, "
            f"남은 정류장={item.remainingStops}, 저상버스={item.lowFloor}, "
            f"혼잡도={item.congestion}"
        )
        for item in arrivals
    ]


def _public_stop_evidence(
    recommendation: RouteRecommendation,
    *,
    origin_lat: float | None,
    origin_lng: float | None,
) -> PublicBusStopEvidence | None:
    try:
        if origin_lat is not None and origin_lng is not None:
            match = _stop_catalog.find_nearest(
                stop_name=recommendation.stopName,
                origin_lat=origin_lat,
                origin_lng=origin_lng,
            )
        else:
            # GPS가 없으면 거리 정렬 없이 이름으로 정류소 증빙을 조회한다.
            match = _stop_catalog.find_by_name(stop_name=recommendation.stopName)
    except Exception:
        return None
    if match is None:
        return None
    return PublicBusStopEvidence(
        datasetName=_stop_catalog.dataset_name,
        endpoint=match.endpoint,
        serviceId=match.service_id,
        stopName=match.stop_name,
        longitude=match.longitude,
        latitude=match.latitude,
        fetchedAt=match.fetched_at,
        totalCount=match.total_count,
    )


def _public_stop_context(evidence: PublicBusStopEvidence | None) -> str | None:
    if evidence is None:
        return None
    return (
        f"{evidence.datasetName}: {evidence.stopName}, 서비스ID={evidence.serviceId}, "
        f"위도={evidence.latitude}, 경도={evidence.longitude}, source={evidence.source.value}"
    )


def _filter_by_route(
    arrivals: list[V3BusArrival],
    route_no: str | None,
    *,
    route_id: str | None = None,
) -> list[V3BusArrival]:
    if not route_no and not route_id:
        return list(arrivals)
    keys = {key.strip() for key in (route_no, route_id) if key and key.strip()}
    return [item for item in arrivals if item.routeNo in keys or item.routeId in keys]


def _validate_origin_pair(origin_lat: float | None, origin_lng: float | None) -> None:
    if (origin_lat is None) != (origin_lng is None):
        raise HTTPException(
            status_code=422,
            detail={
                "error": {
                    "code": "INVALID_ORIGIN",
                    "message": "originLat and originLng must be provided together.",
                    "detail": {"originLat": origin_lat, "originLng": origin_lng},
                }
            },
        )


def _from_gateway_response(
    response: BusArrivalsResponse,
    *,
    route_no: str | None,
    route_id: str | None = None,
    fallback_source: FallbackSource,
) -> V3BusArrivalsResponse:
    arrivals: list[V3BusArrival] = []
    route_keys = {key.strip() for key in (route_no, route_id) if key and key.strip()}
    for item in response.arrivals:
        if route_keys and item.busNo not in route_keys and item.routeId not in route_keys:
            continue
        arrivals.append(
            V3BusArrival(
                busId=None,
                routeNo=item.busNo,
                routeId=item.routeId,
                stopId=response.stopId,
                arrivalMinutes=item.arrivalMinutes,
                arrivalSeconds=item.arrivalSeconds,
                remainingStops=item.remainingStops,
                lowFloor=item.lowFloor,
                congestion=item.congestion.value if item.congestion else None,
            )
        )
    return _arrivals_response(
        stopId=response.stopId,
        routeNo=route_no,
        arrivals=arrivals,
        fallbackSource=fallback_source,
    )


def _arrivals_response(
    *,
    stopId: str,
    routeNo: str | None,
    arrivals: list[V3BusArrival],
    fallbackSource: FallbackSource,
) -> V3BusArrivalsResponse:
    return V3BusArrivalsResponse(
        stopId=stopId,
        routeNo=routeNo,
        arrivals=arrivals,
        fallbackSource=fallbackSource,
        serviceStatus=evaluate_route_service_status(route_no=routeNo, arrivals=arrivals),
    )
