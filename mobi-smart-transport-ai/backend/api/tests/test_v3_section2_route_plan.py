from datetime import datetime, timezone

from fastapi.testclient import TestClient

from app.main import app
from app.schemas.bus_info import BusArrival, BusArrivalsResponse, CongestionLevel
from app.schemas.v3 import FallbackSource, NearbyStopCandidate
from app.services.bus_info_gateway_service import BusInfoGatewayResult
from app.services.cheongju_route_planner import RouteSequence, RouteStopNode, _matches_for
from app.services.firebase_client import get_firebase_client

client = TestClient(app)


def setup_function() -> None:
    get_firebase_client().clear_mock_store()


def test_route_plan_endpoint_is_registered() -> None:
    routes = {
        (route.path, method)
        for route in app.routes
        for method in getattr(route, "methods", set())
    }

    assert ("/bus/route-plan", "GET") in routes


def test_route_plan_calculates_direct_route_using_route_order_and_direction() -> None:
    response = client.get(
        "/bus/route-plan",
        params={
            "q": "상당산성 가고 싶어",
            "originLat": 36.6359,
            "originLng": 127.4596,
            "mode": "mock",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "RESOLVED"
    plan = body["recommendedPlan"]
    assert plan["type"] == "DIRECT"
    assert plan["transferCount"] == 0
    assert plan["segments"][0]["routeNo"] == "862"
    assert plan["segments"][0]["boardStop"]["stopName"] == "사창사거리 정류장"
    assert plan["segments"][0]["boardStop"]["directionHint"].endswith("방향")
    assert "건너편" not in plan["boardingInstruction"]
    assert plan["segments"][0]["arrivals"][0]["routeNo"] == "862"
    assert plan["segments"][0]["arrivalSource"] == "MOCK"


def test_route_plan_calculates_one_transfer_route_when_direct_is_unavailable() -> None:
    response = client.get(
        "/bus/route-plan",
        params={
            "q": "상당산성",
            "originLat": 36.6262,
            "originLng": 127.4312,
            "mode": "mock",
        },
    )

    assert response.status_code == 200
    body = response.json()
    plan = body["recommendedPlan"]
    assert plan["type"] == "ONE_TRANSFER"
    assert plan["transferCount"] == 1
    assert [segment["routeNo"] for segment in plan["segments"]] == ["502", "862"]
    assert plan["segments"][0]["boardStop"]["stopName"] == "청주고속버스터미널 정류장"
    assert plan["segments"][0]["alightStop"]["stopName"] == "사창사거리 정류장"
    assert plan["segments"][1]["boardStop"]["stopName"] == "사창사거리 정류장"
    assert plan["segments"][1]["directionHint"].endswith("방향")
    assert plan["segments"][0]["arrivals"][0]["routeNo"] == "502"


def test_route_plan_defers_to_confirmation_question_for_uncertain_destination() -> None:
    response = client.get(
        "/bus/route-plan",
        params={"q": "상단산성", "originLat": 36.6359, "originLng": 127.4596, "mode": "mock"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "NEEDS_CONFIRMATION"
    assert body["plans"] == []
    assert body["question"] == "혹시 상당산성 맞을까요?"


def test_route_plan_requires_current_location_for_new_destination() -> None:
    response = client.get("/bus/route-plan", params={"q": "상당산성", "mode": "mock"})

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "NOT_FOUND"
    assert body["recommendedPlan"] is None
    assert "위치 권한" in body["question"]


def test_route_plan_does_not_match_opposite_stop_by_name_when_ids_differ() -> None:
    candidate = NearbyStopCandidate(
        stopId="mock-stop-001",
        stopName="사창사거리 정류장",
        latitude=36.6359,
        longitude=127.4596,
        distanceMeters=10,
    )
    opposite_sequence = RouteSequence(
        route_no="502",
        route_id="mock-route-502-east-west",
        source=FallbackSource.MOCK,
        nodes=(
            RouteStopNode(
                stop_id="mock-stop-001-opposite",
                stop_name="사창사거리 정류장",
                order=1,
            ),
            RouteStopNode(
                stop_id="mock-stop-003",
                stop_name="청주고속버스터미널 정류장",
                order=2,
            ),
        ),
    )

    assert _matches_for(opposite_sequence, [candidate]) == []


def test_route_plan_keeps_cache_arrival_source_for_first_boarding_segment() -> None:
    firebase = get_firebase_client()
    firebase.set(
        "/busArrivals/mock-stop-001",
        {
            "stopId": "mock-stop-001",
            "arrivals": [
                {
                    "routeId": "mock-route-862-to-fortress",
                    "busNo": "862",
                    "arrivalMinutes": 3,
                    "remainingStops": 1,
                    "lowFloor": True,
                    "congestion": "LOW",
                    "updatedAt": "2026-06-01T00:00:00+09:00",
                }
            ],
        },
    )

    response = client.get(
        "/bus/route-plan",
        params={"q": "상당산성", "originLat": 36.6359, "originLng": 127.4596, "mode": "mock"},
    )

    assert response.status_code == 200
    segment = response.json()["recommendedPlan"]["segments"][0]
    assert segment["arrivalSource"] == "CACHE"
    assert segment["arrivals"][0]["arrivalMinutes"] == 3
    assert segment["arrivals"][0]["congestion"] == "LOW"


def test_route_plan_preserves_public_api_arrivals_without_inventing_bus_id(monkeypatch) -> None:
    from app.api.routes import v3_bus

    class PublicApiGateway:
        def get_arrivals_with_source(self, stop_id: str):
            return BusInfoGatewayResult(
                response=BusArrivalsResponse(
                    stopId=stop_id,
                    arrivals=[
                        BusArrival(
                            routeId="mock-route-862-to-fortress",
                            busNo="862",
                            arrivalMinutes=4,
                            remainingStops=2,
                            lowFloor=True,
                            congestion=CongestionLevel.UNKNOWN,
                            updatedAt=datetime(2026, 6, 1, tzinfo=timezone.utc),
                        )
                    ],
                ),
                source="PUBLIC_API",
            )

    original_service = v3_bus._service
    monkeypatch.setattr(v3_bus, "_service", PublicApiGateway())
    try:
        response = client.get(
            "/bus/route-plan",
            params={"q": "상당산성", "originLat": 36.6359, "originLng": 127.4596},
        )
    finally:
        monkeypatch.setattr(v3_bus, "_service", original_service)

    assert response.status_code == 200
    segment = response.json()["recommendedPlan"]["segments"][0]
    assert segment["arrivalSource"] == "PUBLIC_API"
    assert segment["arrivals"][0]["busId"] is None
