"""현재 위치 주변 버스정류장 검색 서비스.

기존 CheongjuBusStopsService(승인된 청주 정류소 카탈로그, 서버 메모리 캐시)를
재사용한다. 정류소 목록을 매 요청마다 외부 API로 긁지 않고 캐시(기본 600s)를 쓴다.
카탈로그가 비활성/실패해도 빈 목록으로 안전하게 반환한다.
"""
from __future__ import annotations

from app.schemas.v3 import FallbackSource, utc_now
from app.schemas.v3_map import GeoPoint, NearbyStop, NearbyStopsResponse
from app.services.cheongju_bus_stops_service import CheongjuBusStopsService

_service = CheongjuBusStopsService()


def find_named_stop(
    *,
    stop_name: str,
    origin_lat: float | None = None,
    origin_lng: float | None = None,
) -> NearbyStop | None:
    """Resolve an approved stop coordinate by name without inventing a point."""
    try:
        match = (
            _service.find_nearest(
                stop_name=stop_name,
                origin_lat=origin_lat,
                origin_lng=origin_lng,
            )
            if origin_lat is not None and origin_lng is not None
            else _service.find_by_name(stop_name=stop_name)
        )
    except Exception:
        return None
    if match is None:
        return None
    return NearbyStop(
        stopId=match.service_id,
        stopName=match.stop_name,
        latitude=match.latitude,
        longitude=match.longitude,
        distanceMeters=round(match.distance_meters or 0.0, 1),
        source="PUBLIC_API",
    )


def find_nearby_stops(
    *,
    lat: float,
    lng: float,
    radius_meters: int = 500,
    limit: int = 5,
) -> NearbyStopsResponse:
    origin = GeoPoint(latitude=lat, longitude=lng)
    stops: list[NearbyStop] = []
    fallback = FallbackSource.PUBLIC_API
    try:
        matches = _service.find_nearby(
            origin_lat=lat,
            origin_lng=lng,
            limit=max(1, limit),
            radius_meters=float(radius_meters),
        )
        for match in matches:
            stops.append(
                NearbyStop(
                    stopId=match.service_id,
                    stopName=match.stop_name,
                    latitude=match.latitude,
                    longitude=match.longitude,
                    distanceMeters=round(match.distance_meters or 0.0, 1),
                    source="PUBLIC_API",
                )
            )
        if not stops:
            fallback = FallbackSource.CACHE
    except Exception:
        fallback = FallbackSource.ERROR
        stops = []

    return NearbyStopsResponse(
        origin=origin,
        radiusMeters=radius_meters,
        stops=stops,
        updatedAt=utc_now(),
        fallbackSource=fallback,
    )
