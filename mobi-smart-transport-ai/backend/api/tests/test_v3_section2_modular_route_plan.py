from fastapi.testclient import TestClient

from app.main import app
from app.schemas.v3 import (
    FallbackSource,
    RoutePlanCandidate,
    RoutePlanSegment,
    RoutePlanStop,
    RoutePlanType,
    V3BusArrival,
    V3BusArrivalsResponse,
)
from app.services.cheongju_route_planner import CheongjuRoutePlanner
from app.services.route_ranker import RouteRanker
from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode, RouteStopSequenceCache
from services.public_data.public_data_client.schemas import NormalizedBusRouteNode, NormalizedBusRouteStopsResponse

client = TestClient(app)


def test_route_stop_sequence_cache_indexes_route_numbers_and_node_ids() -> None:
    cache = RouteStopSequenceCache(
        mock_sequences=[
            RouteSequence(
                route_id="route-a",
                route_no="40-2",
                nodes=(
                    RouteStopNode("stop-2", "하차", 2),
                    RouteStopNode("stop-1", "승차", 1),
                ),
            ),
            RouteSequence(
                route_id="route-b",
                route_no="40-2",
                nodes=(RouteStopNode("stop-3", "반대편 승차", 1),),
            ),
        ]
    )

    assert cache.route_ids_for_route_no("40-2") == {"route-a", "route-b"}
    assert cache.route_ids_for_stop("stop-1") == {"route-a"}
    assert cache.common_route_ids("stop-1", "stop-2") == {"route-a"}
    assert cache.can_travel("route-a", "stop-1", "stop-2") is True
    assert cache.can_travel("route-a", "stop-2", "stop-1") is False


def test_route_stop_sequence_cache_loads_all_live_direction_variants() -> None:
    class LiveRouteService:
        def resolve_route_ids(self, city_code: str, route_no: str) -> list[str]:
            return ["route-west", "route-east"]

        def get_route_stops(self, city_code: str, route_id: str) -> NormalizedBusRouteStopsResponse:
            suffix = "west" if route_id == "route-west" else "east"
            return NormalizedBusRouteStopsResponse(
                routeId=route_id,
                nodes=[
                    NormalizedBusRouteNode(nodeId=f"{suffix}-1", nodeNm="첫 정류장", nodeOrd=1),
                    NormalizedBusRouteNode(nodeId=f"{suffix}-2", nodeNm="둘째 정류장", nodeOrd=2),
                ],
            )

    cache = RouteStopSequenceCache(route_service=LiveRouteService())
    sequences = cache.sequences(live=True, route_nos=["502"])

    assert {sequence.route_id for sequence in sequences} == {"route-west", "route-east"}
    assert cache.route_ids_for_route_no("502") == {"route-west", "route-east"}


def test_route_plan_post_accepts_json_request_and_exposes_ready_readiness() -> None:
    response = client.post(
        "/bus/route-plan",
        json={
            "destinationText": "상당산성",
            "originLat": 36.6359,
            "originLng": 127.4596,
            "mode": "mock",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "RESOLVED"
    assert body["readiness"] == "READY"
    assert body["recommendedPlan"]["segments"][0]["routeNo"] == "862"


def test_route_plan_keeps_route_when_arrival_lookup_returns_unknown() -> None:
    planner = CheongjuRoutePlanner(
        arrival_fetcher=lambda stop_id, route_no, route_id: V3BusArrivalsResponse(
            stopId=stop_id,
            routeNo=route_no,
            arrivals=[],
            fallbackSource=FallbackSource.ERROR,
        )
    )

    response = planner.plan(
        heard_text="상당산성",
        origin_lat=36.6359,
        origin_lng=127.4596,
        live=False,
    )

    assert response.status.value == "RESOLVED"
    segment = response.recommendedPlan.segments[0]
    assert segment.arrivals == []
    assert segment.arrivalUnknown is True
    assert segment.arrivalSource == FallbackSource.ERROR


def test_accessibility_ranker_can_prefer_direct_route_over_faster_transfer() -> None:
    ranker = RouteRanker()
    direct = _candidate(
        plan_id="direct",
        transfer_count=0,
        segments=[_segment("40-2", arrival_minutes=12, stop_count=8)],
    )
    transfer = _candidate(
        plan_id="transfer",
        transfer_count=1,
        segments=[
            _segment("502", arrival_minutes=2, stop_count=2),
            _segment("862", arrival_minutes=2, stop_count=2),
        ],
    )

    ranked = ranker.rank([transfer, direct])

    assert ranked[0].planId == "direct"
    assert ranked[0].recommendedReason
    assert ranked[1].rankingEvidence


def _candidate(
    *,
    plan_id: str,
    transfer_count: int,
    segments: list[RoutePlanSegment],
) -> RoutePlanCandidate:
    return RoutePlanCandidate(
        planId=plan_id,
        type=RoutePlanType.DIRECT if transfer_count == 0 else RoutePlanType.ONE_TRANSFER,
        destinationName="상당산성",
        summary="검증용 경로",
        boardingInstruction="산성남문 방향 정류장에서 타면 돼.",
        transferCount=transfer_count,
        totalBusStopCount=sum(segment.stopCount for segment in segments),
        estimatedWalkMeters=100,
        accessibilityScore=0,
        simplicityScore=0,
        score=0,
        segments=segments,
    )


def _segment(route_no: str, *, arrival_minutes: int, stop_count: int) -> RoutePlanSegment:
    return RoutePlanSegment(
        routeNo=route_no,
        routeId=f"route-{route_no}",
        boardStop=RoutePlanStop(stopId=f"board-{route_no}", stopName="승차 정류장"),
        alightStop=RoutePlanStop(stopId=f"alight-{route_no}", stopName="하차 정류장"),
        stopCount=stop_count,
        directionHint="산성남문 방향",
        arrivals=[
            V3BusArrival(
                routeNo=route_no,
                routeId=f"route-{route_no}",
                stopId=f"board-{route_no}",
                arrivalMinutes=arrival_minutes,
            )
        ],
    )
