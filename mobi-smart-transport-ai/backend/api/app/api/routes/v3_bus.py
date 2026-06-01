from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query

from app.schemas.bus_info import BusArrivalsResponse
from app.schemas.v3 import (
    FallbackSource,
    PublicBusStopEvidence,
    RouteRecommendation,
    RouteRecommendResponse,
    RoutePlanningEvidence,
    V3BusArrival,
    V3BusArrivalsResponse,
)
import os

from services.public_data.public_data_client import BusArrivalsService

from app.services import cheongju_route_catalog
from app.services.bus_info_gateway_service import BusInfoGatewayResult, BusInfoGatewayService
from app.services.cheongju_bus_stops_service import CheongjuBusStopsService
from app.services.v3_gemini_service import generate_route_plan_summary

router = APIRouter()
_service = BusInfoGatewayService()
_stop_catalog = CheongjuBusStopsService()

def _is_live_mode() -> bool:
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")


def _resolve_live(mode: str | None) -> bool:
    """요청별 mode가 오면 우선 적용하고, 없으면 전역 env로 폴백한다.

    'API 데이터 테스트' 화면은 항상 mode='live'를 보내므로, 전역 토글 상태나
    서버 재시작과 무관하게 해당 요청은 반드시 실데이터 경로를 탄다.
    """
    if mode:
        return mode.strip().lower() == "live"
    return _is_live_mode()


def _gateway_for(live: bool) -> BusInfoGatewayService:
    """요청별 모드를 강제한 게이트웨이. 전역 env와 무관하게 mock/live를 고정한다."""
    return BusInfoGatewayService(public_data_service=BusArrivalsService(use_mock=not live))


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
}


@router.get("/route-recommend", response_model=RouteRecommendResponse)
def route_recommend(
    destination: str = Query(min_length=1),
    originLat: float | None = Query(default=None, ge=-90, le=90),
    originLng: float | None = Query(default=None, ge=-180, le=180),
    mode: str | None = Query(default=None),
) -> RouteRecommendResponse:
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
    planning_result = None
    planning_data_source = None
    stop_evidence = None
    if originLat is not None and originLng is not None:
        stop_evidence = _public_stop_evidence(
            recommendation,
            origin_lat=originLat,
            origin_lng=originLng,
        )
        planning_data_source, evidence = _planning_evidence(recommendation, live=live)
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
        evidence=evidence if originLat is not None and originLng is not None else None,
    )


@router.get("/arrivals", response_model=V3BusArrivalsResponse)
def arrivals(
    stopId: str = Query(min_length=1),
    routeNo: str | None = None,
    mode: str | None = Query(default=None),
) -> V3BusArrivalsResponse:
    normalized_stop_id = stopId.strip()
    live = _resolve_live(mode)

    # Cache/live public data must win over the local V3 mock catalog when present,
    # because it represents fresher or externally supplied information.
    try:
        gateway_result = _gateway_for(live).get_arrivals_with_source(normalized_stop_id)
    except HTTPException:
        if not live:
            mock = _mock_response(normalized_stop_id, route_no=routeNo)
            if mock is not None:
                return mock
        return V3BusArrivalsResponse(
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


def _mock_response(stop_id: str, *, route_no: str | None) -> V3BusArrivalsResponse | None:
    catalog = _MOCK_ARRIVALS_BY_STOP.get(stop_id)
    if catalog is None:
        return None
    arrivals = _filter_by_route(catalog, route_no)
    return V3BusArrivalsResponse(
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
    origin_lat: float,
    origin_lng: float,
) -> PublicBusStopEvidence | None:
    try:
        match = _stop_catalog.find_nearest(
            stop_name=recommendation.stopName,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
        )
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


def _filter_by_route(arrivals: list[V3BusArrival], route_no: str | None) -> list[V3BusArrival]:
    if not route_no:
        return list(arrivals)
    route_key = route_no.strip()
    return [item for item in arrivals if item.routeNo == route_key or item.routeId == route_key]


def _from_gateway_response(
    response: BusArrivalsResponse,
    *,
    route_no: str | None,
    fallback_source: FallbackSource,
) -> V3BusArrivalsResponse:
    arrivals: list[V3BusArrival] = []
    route_key = route_no.strip() if route_no else None
    for item in response.arrivals:
        if route_key and item.busNo != route_key and item.routeId != route_key:
            continue
        arrivals.append(
            V3BusArrival(
                busId=None,
                routeNo=item.busNo,
                routeId=item.routeId,
                stopId=response.stopId,
                arrivalMinutes=item.arrivalMinutes,
                remainingStops=item.remainingStops,
                lowFloor=item.lowFloor,
                congestion=item.congestion.value if item.congestion else None,
            )
        )
    return V3BusArrivalsResponse(
        stopId=response.stopId,
        routeNo=route_no,
        arrivals=arrivals,
        fallbackSource=fallback_source,
    )
