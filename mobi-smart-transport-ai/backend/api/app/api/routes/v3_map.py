"""실시간 지도 지원 API: 근처 정류장 검색 + 보행경로(TMAP).

모든 외부 API 호출은 백엔드 전용이며, API key는 응답/로그에 노출하지 않는다.
"""
from __future__ import annotations

import os

from fastapi import APIRouter, Query

from app.schemas.v3_map import NearbyStopsResponse, WalkingRouteResponse
from app.services import nearby_stops_service, walking_route_service

router = APIRouter()


def _resolve_live(mode: str | None) -> bool:
    if mode:
        return mode.strip().lower() == "live"
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")


@router.get("/nearby-stops", response_model=NearbyStopsResponse)
def nearby_stops(
    lat: float = Query(ge=-90, le=90),
    lng: float = Query(ge=-180, le=180),
    radiusMeters: int = Query(default=500, ge=10, le=3000),
    limit: int = Query(default=5, ge=1, le=20),
    mode: str | None = Query(default=None),
) -> NearbyStopsResponse:
    return nearby_stops_service.find_nearby_stops(
        lat=lat, lng=lng, radius_meters=radiusMeters, limit=limit
    )


@router.get("/walking-route", response_model=WalkingRouteResponse)
def walking_route(
    originLat: float = Query(ge=-90, le=90),
    originLng: float = Query(ge=-180, le=180),
    destLat: float = Query(ge=-90, le=90),
    destLng: float = Query(ge=-180, le=180),
    destName: str | None = Query(default=None),
    mode: str | None = Query(default=None),
) -> WalkingRouteResponse:
    return walking_route_service.get_walking_route(
        origin_lat=originLat,
        origin_lng=originLng,
        dest_lat=destLat,
        dest_lng=destLng,
        dest_name=destName,
        live=_resolve_live(mode),
    )
