from datetime import datetime
from enum import Enum
from pydantic import Field

from app.schemas.base import StrictApiModel


class CongestionLevel(str, Enum):
    LOW = "LOW"
    NORMAL = "NORMAL"
    HIGH = "HIGH"
    UNKNOWN = "UNKNOWN"


class BusArrival(StrictApiModel):
    routeId: str
    busNo: str
    arrivalMinutes: int = Field(ge=0)
    remainingStops: int | None = Field(default=None, ge=0)
    lowFloor: bool
    congestion: CongestionLevel
    updatedAt: datetime


class BusArrivalsResponse(StrictApiModel):
    stopId: str
    arrivals: list[BusArrival]
