from datetime import datetime
from enum import Enum
from pydantic import BaseModel, ConfigDict, Field


class CongestionLevel(str, Enum):
    LOW = "LOW"
    NORMAL = "NORMAL"
    HIGH = "HIGH"
    UNKNOWN = "UNKNOWN"


class StrictPublicDataModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class NormalizedBusArrival(StrictPublicDataModel):
    routeId: str
    busNo: str
    arrivalMinutes: int = Field(ge=0)
    remainingStops: int | None = Field(default=None, ge=0)
    lowFloor: bool
    congestion: CongestionLevel
    updatedAt: datetime


class NormalizedBusArrivalsResponse(StrictPublicDataModel):
    stopId: str
    arrivals: list[NormalizedBusArrival]
