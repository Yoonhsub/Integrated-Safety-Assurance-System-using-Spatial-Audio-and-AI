"""실시간 지도/내비게이션 응답 스키마.

기존 v3 스키마(StrictApiModel, FallbackSource 등)를 재사용하고, 지도 패널이
필요로 하는 보행경로/근처정류장/통합 실시간 상태만 추가로 정의한다.
"""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import Field

from app.schemas.base import StrictApiModel
from app.schemas.v3 import (
    AgentTraceEvent,
    FallbackSource,
    RoutePlanServiceStatus,
    V3BusArrival,
    V3BusPosition,
)


class GeoPoint(StrictApiModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class WalkingRouteInstruction(StrictApiModel):
    text: str
    distanceMeters: float | None = Field(default=None, ge=0)
    durationSeconds: int | None = Field(default=None, ge=0)


class WalkingRouteResponse(StrictApiModel):
    status: Literal["READY", "FALLBACK", "ERROR"]
    provider: str
    origin: GeoPoint
    destination: GeoPoint
    destName: str | None = None
    totalDistanceMeters: float | None = Field(default=None, ge=0)
    totalDurationSeconds: int | None = Field(default=None, ge=0)
    polyline: list[GeoPoint] = Field(default_factory=list)
    instructions: list[WalkingRouteInstruction] = Field(default_factory=list)
    fallbackUsed: bool = False
    message: str | None = None
    updatedAt: datetime


class NearbyStop(StrictApiModel):
    stopId: str
    stopName: str
    latitude: float
    longitude: float
    distanceMeters: float = Field(ge=0)
    source: str = "PUBLIC_API"


class NearbyStopsResponse(StrictApiModel):
    origin: GeoPoint
    radiusMeters: int = Field(ge=0)
    stops: list[NearbyStop] = Field(default_factory=list)
    updatedAt: datetime
    fallbackSource: FallbackSource = FallbackSource.PUBLIC_API


class LiveStatusResponse(StrictApiModel):
    """Flutter 실시간 추적 패널이 한 번에 받는 통합 상태."""

    sessionId: str | None = None
    routeNo: str
    routeId: str | None = None
    userLocation: GeoPoint | None = None
    nearbyStops: list[NearbyStop] = Field(default_factory=list)
    selectedBoardStop: NearbyStop | None = None
    selectedAlightStop: NearbyStop | None = None
    walkingRouteToBoardStop: WalkingRouteResponse | None = None
    walkingRouteFromAlightStop: WalkingRouteResponse | None = None
    arrivals: list[V3BusArrival] = Field(default_factory=list)
    busPositions: list[V3BusPosition] = Field(default_factory=list)
    serviceStatus: RoutePlanServiceStatus | None = None
    congestion: str = "미제공"
    lastUpdatedAt: datetime
    nextRefreshSeconds: int = 30
    warnings: list[str] = Field(default_factory=list)
    fallbackSource: FallbackSource = FallbackSource.ERROR
    trace: list[AgentTraceEvent] = Field(default_factory=list)
    traceId: str | None = None
