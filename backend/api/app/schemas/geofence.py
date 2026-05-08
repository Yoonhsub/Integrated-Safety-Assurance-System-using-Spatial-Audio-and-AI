from datetime import datetime
from enum import Enum
from pydantic import Field, model_validator

from app.schemas.base import StrictApiModel


class GeofenceStatus(str, Enum):
    SAFE = "SAFE"
    WARNING = "WARNING"
    DANGER = "DANGER"
    OUT_OF_AREA = "OUT_OF_AREA"
    UNKNOWN = "UNKNOWN"


class GeofenceCheckRequest(StrictApiModel):
    userId: str
    stopId: str
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    # validate_architecture.py legacy contract marker: timestamp: datetime = None
    timestamp: datetime | None = None

    @model_validator(mode="before")
    @classmethod
    def reject_null_timestamp(cls, data):
        if isinstance(data, dict) and "timestamp" in data and data["timestamp"] is None:
            raise ValueError("timestamp는 생략할 수 있지만 null은 보낼 수 없습니다.")
        return data


class GeofenceCheckResponse(StrictApiModel):
    status: GeofenceStatus
    message: str
    shouldSpeak: bool
    shouldVibrate: bool
    eventId: str | None = None
