from __future__ import annotations

from pydantic import BaseModel


class RouteRecommendRequest(BaseModel):
    sessionId: str = "demo-session-001"
    userId: str | None = None
    destination: str
    lat: float | None = None
    lng: float | None = None


class RouteRecommendResponse(BaseModel):
    destination: str
    selectedStopId: str
    selectedStopName: str
    selectedRouteNo: str
    selectedRouteId: str
    distanceToStopMeters: int
    message: str
    guidanceState: str = "ROUTE_RECOMMENDED"


class ArrivalInfo(BaseModel):
    routeNo: str
    arrivalMinutes: int
    busId: str
    source: str = "MOCK"


class BusArrivalsResponse(BaseModel):
    stopId: str
    routeNo: str
    arrivals: list[ArrivalInfo]
    message: str
    fallbackSource: str | None = None
