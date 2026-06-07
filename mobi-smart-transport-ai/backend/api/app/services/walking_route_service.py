"""보행경로 서비스: TMAP 보행자 경로 + 직선거리 fallback + TTL 캐시.

TMAP 호출은 backend 전용이며, key는 tmap_pedestrian_client가 .env에서만 읽는다.
TMAP 실패/비활성 시 직선거리 기반 안내로 안전하게 fallback한다.
"""
from __future__ import annotations

import math
import os
import time

from app.schemas.v3 import utc_now
from app.schemas.v3_map import (
    GeoPoint,
    WalkingRouteInstruction,
    WalkingRouteResponse,
)
from app.services import tmap_pedestrian_client

# (round_key) -> (expires_at_monotonic, WalkingRouteResponse)
_CACHE: dict[tuple, tuple[float, WalkingRouteResponse]] = {}
_WALK_SPEED_MPS = 1.2  # 보행 평균 속도(약 4.3km/h)


def _cache_ttl_seconds() -> float:
    try:
        return max(0.0, float(os.getenv("TMAP_PEDESTRIAN_CACHE_TTL_SECONDS", "300")))
    except ValueError:
        return 300.0


def _distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6_371_000.0
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * radius * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _cache_key(origin_lat, origin_lng, dest_lat, dest_lng, live) -> tuple:
    return (
        round(origin_lat, 5),
        round(origin_lng, 5),
        round(dest_lat, 5),
        round(dest_lng, 5),
        bool(live),
    )


def get_walking_route(
    *,
    origin_lat: float,
    origin_lng: float,
    dest_lat: float,
    dest_lng: float,
    dest_name: str | None = None,
    live: bool = True,
) -> WalkingRouteResponse:
    key = _cache_key(origin_lat, origin_lng, dest_lat, dest_lng, live)
    now = time.monotonic()
    cached = _CACHE.get(key)
    if cached is not None and cached[0] > now:
        return cached[1]

    origin = GeoPoint(latitude=origin_lat, longitude=origin_lng)
    destination = GeoPoint(latitude=dest_lat, longitude=dest_lng)

    result = None
    if live:
        result = tmap_pedestrian_client.fetch_pedestrian_route(
            start_lat=origin_lat,
            start_lng=origin_lng,
            end_lat=dest_lat,
            end_lng=dest_lng,
            start_name="현위치",
            end_name=dest_name or "정류장",
        )

    if result is not None and result.polyline:
        response = WalkingRouteResponse(
            status="READY",
            provider="TMAP",
            origin=origin,
            destination=destination,
            destName=dest_name,
            totalDistanceMeters=result.total_distance_meters,
            totalDurationSeconds=result.total_time_seconds,
            polyline=[GeoPoint(latitude=lat, longitude=lng) for lat, lng in result.polyline],
            instructions=[WalkingRouteInstruction(**item) for item in result.instructions],
            fallbackUsed=False,
            message=None,
            updatedAt=utc_now(),
        )
    else:
        response = _straight_line_fallback(origin, destination, dest_name)

    ttl = _cache_ttl_seconds()
    if ttl > 0:
        _CACHE[key] = (now + ttl, response)
    return response


def _straight_line_fallback(
    origin: GeoPoint, destination: GeoPoint, dest_name: str | None
) -> WalkingRouteResponse:
    distance = _distance_meters(
        origin.latitude, origin.longitude, destination.latitude, destination.longitude
    )
    duration = int(round(distance / _WALK_SPEED_MPS)) if distance > 0 else 0
    target = dest_name or "승차 정류장"
    return WalkingRouteResponse(
        status="FALLBACK",
        provider="STRAIGHT_LINE",
        origin=origin,
        destination=destination,
        destName=dest_name,
        totalDistanceMeters=round(distance, 1),
        totalDurationSeconds=duration,
        polyline=[origin, destination],
        instructions=[
            WalkingRouteInstruction(
                text=f"{target}까지 직선거리 약 {int(round(distance))}m 안내(보행경로 미확인)",
                distanceMeters=round(distance, 1),
                durationSeconds=duration,
            )
        ],
        fallbackUsed=True,
        message="보행경로를 확인하지 못해 직선거리 기준으로 안내합니다.",
        updatedAt=utc_now(),
    )
