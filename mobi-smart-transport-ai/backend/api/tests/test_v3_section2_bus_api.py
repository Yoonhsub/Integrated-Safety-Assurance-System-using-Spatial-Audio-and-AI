from datetime import datetime, timezone

from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.main import app
from app.schemas.bus_info import BusArrival, BusArrivalsResponse, CongestionLevel
from app.services.bus_info_gateway_service import BusInfoGatewayResult
from app.services.cheongju_bus_stops_service import CheongjuBusStopMatch, CheongjuBusStopsService
from app.services.firebase_client import get_firebase_client

client = TestClient(app)


def setup_function() -> None:
    get_firebase_client().clear_mock_store()


def test_route_recommendation_registered_destinations_and_aliases() -> None:
    cases = [
        ("사창사거리", "mock-stop-001", "502"),
        ("사직사거리", "mock-stop-001", "502"),
        ("충북대학교 병원", "mock-stop-002", "823"),
        ("청주터미널", "mock-stop-003", "502"),
    ]

    for destination, stop_id, route_no in cases:
        response = client.get("/bus/route-recommend", params={"destination": destination})
        assert response.status_code == 200
        body = response.json()
        assert body["fallbackSource"] == "MOCK"
        assert body["recommendations"][0]["stopId"] == stop_id
        assert body["recommendations"][0]["routeNo"] == route_no


def test_route_recommendation_unknown_destination_is_explicit_error() -> None:
    response = client.get("/bus/route-recommend", params={"destination": "없는목적지"})

    assert response.status_code == 404
    body = response.json()
    assert body["error"]["code"] == "UNKNOWN_DESTINATION"
    assert body["error"]["detail"]["destination"] == "없는목적지"


def test_location_aware_route_recommendation_uses_pro_summary(monkeypatch) -> None:
    from app.api.routes import v3_bus

    monkeypatch.setenv("CHEONGJU_BUS_STOPS_ENABLED", "false")
    monkeypatch.setattr(
        v3_bus,
        "generate_route_plan_summary",
        lambda **_: (
            "gemini-2.5-pro",
            "현재 위치 기준으로 검증된 502번 후보를 우선 안내할게.",
            [{"title": "사창사거리", "uri": "https://maps.google.com/example"}],
        ),
    )

    response = client.get(
        "/bus/route-recommend",
        params={"destination": "사창사거리", "originLat": 36.6281, "originLng": 127.4562},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["recommendations"][0]["routeNo"] == "502"
    assert body["usedGemini"] is True
    assert body["planningModel"] == "gemini-2.5-pro"
    assert body["planningDataSource"] == "MOCK"
    assert body["mapsGrounded"] is True
    assert body["mapsEvidence"][0]["title"] == "사창사거리"
    assert body["evidence"]["source"] == "MOCK"
    assert body["evidence"]["arrivals"][0]["routeNo"] == "502"
    assert "현재 위치" in body["planningSummary"]


def test_location_aware_route_recommendation_passes_cached_arrivals_to_pro(monkeypatch) -> None:
    from app.api.routes import v3_bus

    monkeypatch.setenv("CHEONGJU_BUS_STOPS_ENABLED", "false")
    captured = {}
    firebase = get_firebase_client()
    firebase.set(
        "/busArrivals/mock-stop-001",
        {
            "stopId": "mock-stop-001",
            "arrivals": [
                {
                    "routeId": "mock-route-502",
                    "busNo": "502",
                    "arrivalMinutes": 2,
                    "remainingStops": 1,
                    "lowFloor": True,
                    "congestion": "LOW",
                    "updatedAt": "2026-05-30T00:00:00+09:00",
                }
            ],
        },
    )

    def fake_plan(**kwargs):
        captured.update(kwargs)
        return "gemini-2.5-pro", "캐시 기반 후보를 계산했어.", []

    monkeypatch.setattr(v3_bus, "generate_route_plan_summary", fake_plan)

    response = client.get(
        "/bus/route-recommend",
        params={"destination": "사창사거리", "originLat": 36.6281, "originLng": 127.4562},
    )

    assert response.status_code == 200
    assert response.json()["planningDataSource"] == "CACHE"
    assert captured["arrival_source"] == "CACHE"
    assert "2분 뒤" in captured["arrival_context"][0]
    assert response.json()["evidence"]["source"] == "CACHE"
    assert response.json()["evidence"]["arrivals"][0]["arrivalMinutes"] == 2


def test_location_aware_route_recommendation_includes_verified_stop_catalog_evidence(monkeypatch) -> None:
    from app.api.routes import v3_bus

    captured = {}

    class FakeStopCatalog:
        dataset_name = "충청북도_청주시_버스정보시스템_정류소_20250401"

        def find_nearest(self, **_):
            return CheongjuBusStopMatch(
                service_id="1933",
                stop_name="사창사거리",
                longitude=127.4596675,
                latitude=36.63594787,
                endpoint="https://api.odcloud.kr/api/15041896/v1/example",
                fetched_at=datetime(2026, 6, 1, tzinfo=timezone.utc),
                total_count=3402,
            )

    def fake_plan(**kwargs):
        captured.update(kwargs)
        return "gemini-2.5-pro", "공공 API 정류소 근거를 확인했어.", []

    monkeypatch.setattr(v3_bus, "_stop_catalog", FakeStopCatalog())
    monkeypatch.setattr(v3_bus, "generate_route_plan_summary", fake_plan)

    response = client.get(
        "/bus/route-recommend",
        params={"destination": "사창사거리", "originLat": 36.6281, "originLng": 127.4562},
    )

    assert response.status_code == 200
    evidence = response.json()["stopEvidence"]
    assert evidence["source"] == "PUBLIC_API"
    assert evidence["serviceId"] == "1933"
    assert evidence["totalCount"] == 3402
    assert "서비스ID=1933" in captured["public_stop_context"]


def test_cheongju_stop_catalog_selects_nearest_exact_match(monkeypatch) -> None:
    import httpx

    monkeypatch.setenv("CHEONGJU_BUS_STOPS_ENABLED", "true")
    monkeypatch.setenv("PUBLIC_DATA_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.params["serviceKey"] == "test-key"
        return httpx.Response(
            200,
            json={
                "totalCount": 2,
                "data": [
                    {"서비스ID": 1933, "정류소명": "사창사거리", "좌표(X)": "127.4596675", "좌표(Y)": "36.63594787"},
                    {"서비스ID": 1553, "정류소명": "사창사거리", "좌표(X)": "127.4613592", "좌표(Y)": "36.63486487"},
                ],
            },
        )

    service = CheongjuBusStopsService(client=httpx.Client(transport=httpx.MockTransport(handler)))
    match = service.find_nearest(
        stop_name="사창사거리 정류장",
        origin_lat=36.6350,
        origin_lng=127.4610,
    )

    assert match is not None
    assert match.service_id == "1553"
    assert match.total_count == 2


def test_maps_grounding_supports_without_chunks_keep_coordinate_evidence() -> None:
    from app.services.v3_gemini_service import _maps_sources

    sources = _maps_sources(
        {
            "candidates": [
                {
                    "groundingMetadata": {
                        "groundingSupports": [
                            {"segment": {"text": "grounded"}, "groundingChunkIndices": [0]}
                        ]
                    }
                }
            ]
        },
        origin_lat=36.6281,
        origin_lng=127.4562,
    )

    assert sources == [
        {
            "title": "Google Maps grounding 위치 관계",
            "uri": "https://maps.google.com/?q=36.6281,127.4562",
        }
    ]


def test_mock_arrivals_keep_stop_and_route_consistent_and_do_not_fake_congestion() -> None:
    response = client.get("/bus/arrivals", params={"stopId": "mock-stop-001", "routeNo": "502"})

    assert response.status_code == 200
    body = response.json()
    assert body["stopId"] == "mock-stop-001"
    assert body["routeNo"] == "502"
    assert body["fallbackSource"] == "MOCK"
    assert [item["busId"] for item in body["arrivals"]] == ["BUS_2", "BUS_502_NEXT"]
    assert [item["arrivalMinutes"] for item in body["arrivals"]] == [6, 13]
    assert all(item["routeNo"] == "502" for item in body["arrivals"])
    assert all(item["routeId"] == "mock-route-502" for item in body["arrivals"])
    assert all(item["stopId"] == "mock-stop-001" for item in body["arrivals"])
    assert all(item["congestion"] is None for item in body["arrivals"])


def test_arrivals_can_distinguish_first_and_second_502_bus_for_target_bus_id() -> None:
    response = client.get("/bus/arrivals", params={"stopId": "mock-stop-001", "routeNo": "502"})

    assert response.status_code == 200
    arrivals = response.json()["arrivals"]
    assert arrivals[0]["busId"] == "BUS_2"
    assert arrivals[1]["busId"] == "BUS_502_NEXT"
    assert arrivals[0]["arrivalMinutes"] < arrivals[1]["arrivalMinutes"]


def test_cache_fallback_source_wins_over_local_mock_catalog() -> None:
    firebase = get_firebase_client()
    firebase.set(
        "/busArrivals/mock-stop-001",
        {
            "stopId": "mock-stop-001",
            "arrivals": [
                {
                    "routeId": "CACHE-502",
                    "busNo": "502",
                    "arrivalMinutes": 2,
                    "remainingStops": 1,
                    "lowFloor": False,
                    "congestion": "LOW",
                    "updatedAt": "2026-05-30T00:00:00+09:00",
                }
            ],
        },
    )

    response = client.get("/bus/arrivals", params={"stopId": "mock-stop-001", "routeNo": "502"})

    assert response.status_code == 200
    body = response.json()
    assert body["fallbackSource"] == "CACHE"
    assert len(body["arrivals"]) == 1
    assert body["arrivals"][0]["routeId"] == "CACHE-502"
    assert body["arrivals"][0]["busId"] is None
    assert body["arrivals"][0]["congestion"] == "LOW"


def test_missing_public_api_key_in_live_mode_falls_back_to_v3_mock(monkeypatch) -> None:
    from app.api.routes import v3_bus

    monkeypatch.setenv("PUBLIC_DATA_USE_MOCK", "false")
    monkeypatch.delenv("PUBLIC_DATA_API_KEY", raising=False)

    try:
        response = client.get("/bus/arrivals", params={"stopId": "mock-stop-001", "routeNo": "502"})
    finally:
        public_data_service = getattr(v3_bus._service, "public_data_service", None)
        if public_data_service is not None and hasattr(public_data_service, "_lazy_live_provider"):
            public_data_service._lazy_live_provider = None

    assert response.status_code == 200
    body = response.json()
    assert body["fallbackSource"] == "MOCK"
    assert body["arrivals"][0]["busId"] == "BUS_2"


def test_public_data_failure_falls_back_to_local_mock_for_demo_stop(monkeypatch) -> None:
    from app.api.routes import v3_bus

    class BrokenGateway:
        def get_arrivals_with_source(self, stop_id: str):
            raise HTTPException(status_code=503, detail="public data down")

    original_service = v3_bus._service
    monkeypatch.setattr(v3_bus, "_service", BrokenGateway())
    try:
        response = client.get("/bus/arrivals", params={"stopId": "mock-stop-001", "routeNo": "502"})
    finally:
        monkeypatch.setattr(v3_bus, "_service", original_service)

    assert response.status_code == 200
    body = response.json()
    assert body["fallbackSource"] == "MOCK"
    assert body["arrivals"][0]["busId"] == "BUS_2"


def test_public_api_success_source_is_preserved_without_inventing_bus_id(monkeypatch) -> None:
    from app.api.routes import v3_bus

    class PublicApiGateway:
        def get_arrivals_with_source(self, stop_id: str):
            return BusInfoGatewayResult(
                response=BusArrivalsResponse(
                    stopId=stop_id,
                    arrivals=[
                        BusArrival(
                            routeId="PUBLIC-502",
                            busNo="502",
                            arrivalMinutes=4,
                            remainingStops=2,
                            lowFloor=True,
                            congestion=CongestionLevel.UNKNOWN,
                            updatedAt=datetime(2026, 5, 30, tzinfo=timezone.utc),
                        )
                    ],
                ),
                source="PUBLIC_API",
            )

    original_service = v3_bus._service
    monkeypatch.setattr(v3_bus, "_service", PublicApiGateway())
    try:
        response = client.get("/bus/arrivals", params={"stopId": "real-stop-001", "routeNo": "502"})
    finally:
        monkeypatch.setattr(v3_bus, "_service", original_service)

    assert response.status_code == 200
    body = response.json()
    assert body["fallbackSource"] == "PUBLIC_API"
    assert body["arrivals"][0]["routeId"] == "PUBLIC-502"
    assert body["arrivals"][0]["busId"] is None


def test_explicit_live_mode_overrides_global_mock_setting(monkeypatch) -> None:
    from app.api.routes import v3_bus

    calls = []

    class PublicApiGateway:
        def get_arrivals_with_source(self, stop_id: str):
            return BusInfoGatewayResult(
                response=BusArrivalsResponse(
                    stopId=stop_id,
                    arrivals=[
                        BusArrival(
                            routeId="PUBLIC-862",
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

    def fake_gateway_for(live: bool):
        calls.append(live)
        return PublicApiGateway()

    monkeypatch.setenv("PUBLIC_DATA_USE_MOCK", "true")
    monkeypatch.setattr(v3_bus, "_gateway_for", fake_gateway_for)

    response = client.get(
        "/bus/arrivals",
        params={"stopId": "real-stop-001", "routeNo": "862", "mode": "live"},
    )

    assert response.status_code == 200
    assert calls == [True]
    assert response.json()["fallbackSource"] == "PUBLIC_API"
    assert response.json()["arrivals"][0]["routeNo"] == "862"


def test_arrivals_rejects_blank_stop_id_and_unknown_mode() -> None:
    blank = client.get("/bus/arrivals", params={"stopId": "   ", "mode": "mock"})
    unknown_mode = client.get("/bus/arrivals", params={"stopId": "mock-stop-001", "mode": "preview"})

    assert blank.status_code == 422
    assert unknown_mode.status_code == 422


def test_tago_lowercase_arrival_fields_are_normalized() -> None:
    from services.public_data.public_data_client.bus_arrivals_service import LiveBusArrivalsProvider

    arrivals = LiveBusArrivalsProvider()._normalize_arrivals(
        [
            {
                "routeid": "CJB270086200",
                "routeno": "862",
                "arrtime": "240",
                "arrprevstationcnt": "3",
                "vehicletp": "1",
            }
        ]
    )

    assert len(arrivals) == 1
    assert arrivals[0].routeId == "CJB270086200"
    assert arrivals[0].busNo == "862"
    assert arrivals[0].arrivalMinutes == 4
    assert arrivals[0].remainingStops == 3
    assert arrivals[0].lowFloor is True


def test_tago_lowercase_route_and_stop_fields_are_parsed() -> None:
    import httpx

    from services.public_data.public_data_client.bus_route_service import BusRouteService

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/getRouteNoList"):
            return httpx.Response(
                200,
                json={
                    "response": {
                        "body": {
                            "items": {
                                "item": [{"routeid": "CJB270086200", "routeno": "862"}],
                            }
                        }
                    }
                },
            )
        return httpx.Response(
            200,
            json={
                "response": {
                    "body": {
                        "items": {
                            "item": [
                                {"nodeid": "CJB283000215", "nodenm": "사창사거리", "nodeord": "1"},
                                {"nodeid": "CJB283000999", "nodenm": "상당산성", "nodeord": "2"},
                            ],
                        }
                    }
                }
            },
        )

    service = BusRouteService(
        api_key="test-key",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    route_id = service.resolve_route_id("33010", "862")
    route_ids = service.resolve_route_ids("33010", "862")
    stops = service.get_route_stops("33010", route_id)

    assert route_id == "CJB270086200"
    assert route_ids == ["CJB270086200"]
    assert [node.nodeId for node in stops.nodes] == ["CJB283000215", "CJB283000999"]
    assert [node.nodeNm for node in stops.nodes] == ["사창사거리", "상당산성"]
