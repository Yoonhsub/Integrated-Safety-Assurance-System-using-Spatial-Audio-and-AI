from datetime import datetime, timezone
from types import SimpleNamespace

from app.schemas.v3 import FallbackSource, V3BusArrival, V3BusArrivalsResponse, utc_now
from app.schemas.v3_map import GeoPoint, WalkingRouteResponse
from app.schemas.v3_map import NearbyStop
from app.services import nearby_stops_service
from app.services.cheongju_bus_stops_service import CheongjuBusStopMatch
from app.services import live_status_service


def test_board_coordinate_falls_back_to_approved_named_stop(monkeypatch) -> None:
    from app.api.routes import v3_bus

    monkeypatch.setattr(v3_bus, "_route_nodes", lambda **_: {})
    monkeypatch.setattr(
        live_status_service.nearby_stops_service,
        "find_named_stop",
        lambda **_: NearbyStop(
            stopId="1676",
            stopName="충북대학교중문",
            latitude=36.63363092,
            longitude=127.4604582,
            distanceMeters=263.7,
            source="PUBLIC_API",
        ),
    )

    board, alight = live_status_service._board_alight_coords(
        "20-1",
        "CJB270002900",
        "CJB283000216",
        None,
        None,
        None,
        None,
        None,
        "충북대학교중문",
        None,
        36.6359,
        127.4596,
    )

    assert board == (36.63363092, 127.4604582)
    assert alight is None


def test_live_status_refreshes_every_30_seconds_and_includes_egress_walk(monkeypatch) -> None:
    live_status_service._CACHE.clear()
    monkeypatch.setenv("LIVE_STATUS_CACHE_TTL_SECONDS", "0")
    monkeypatch.setattr(
        live_status_service,
        "get_arrivals_tool",
        lambda **_: V3BusArrivalsResponse(
            stopId="BOARD",
            routeNo="851",
            arrivals=[
                V3BusArrival(
                    busId="BUS-851",
                    routeNo="851",
                    routeId="ROUTE-851",
                    stopId="BOARD",
                    arrivalMinutes=8,
                    remainingStops=5,
                )
            ],
            fallbackSource=FallbackSource.PUBLIC_API,
        ),
    )
    monkeypatch.setattr(
        live_status_service.nearby_stops_service,
        "find_nearby_stops",
        lambda **_: SimpleNamespace(stops=[]),
    )
    walking_calls = []

    def walking_route(**kwargs):
        walking_calls.append(kwargs)
        return WalkingRouteResponse(
            status="READY",
            provider="TMAP",
            origin=GeoPoint(latitude=kwargs["origin_lat"], longitude=kwargs["origin_lng"]),
            destination=GeoPoint(latitude=kwargs["dest_lat"], longitude=kwargs["dest_lng"]),
            destName=kwargs["dest_name"],
            totalDistanceMeters=120.0,
            totalDurationSeconds=180,
            polyline=[],
            instructions=[],
            updatedAt=utc_now(),
        )

    monkeypatch.setattr(live_status_service.walking_route_service, "get_walking_route", walking_route)

    result = live_status_service.get_live_status(
        session_id="refresh-30s",
        route_no="851",
        route_id="ROUTE-851",
        board_stop_id="BOARD",
        alight_stop_id="ALIGHT",
        user_lat=36.635,
        user_lng=127.459,
        board_lat=36.636,
        board_lng=127.460,
        alight_lat=36.640,
        alight_lng=127.470,
        dest_lat=36.641,
        dest_lng=127.471,
        board_stop_name="승차 정류장",
        alight_stop_name="하차 정류장",
        dest_name="목적지",
        mode="mock",
    )

    assert result.nextRefreshSeconds == 30
    assert result.walkingRouteToBoardStop is not None
    assert result.walkingRouteFromAlightStop is not None
    assert [call["dest_name"] for call in walking_calls] == ["승차 정류장", "목적지"]


def test_live_status_cache_is_shorter_than_refresh_interval_by_default(monkeypatch) -> None:
    monkeypatch.delenv("LIVE_STATUS_CACHE_TTL_SECONDS", raising=False)

    assert live_status_service._cache_ttl_seconds() == 15.0


def test_named_stop_resolves_odsay_composite_name_through_approved_catalog(monkeypatch) -> None:
    calls = []

    def find_by_name(*, stop_name):
        calls.append(stop_name)
        if stop_name != "충북대학교병원":
            return None
        return CheongjuBusStopMatch(
            service_id="1684",
            stop_name="충북대학교병원",
            longitude=127.4629363,
            latitude=36.62386407,
            endpoint="https://api.odcloud.kr/api/example",
            fetched_at=datetime(2026, 6, 1, tzinfo=timezone.utc),
            total_count=3402,
        )

    monkeypatch.setattr(nearby_stops_service._service, "find_by_name", find_by_name)

    result = nearby_stops_service.find_named_stop(
        stop_name="충북대학교병원.더샵청주그리니티"
    )

    assert calls == ["충북대학교병원.더샵청주그리니티", "충북대학교병원"]
    assert result is not None
    assert result.stopId == "1684"
