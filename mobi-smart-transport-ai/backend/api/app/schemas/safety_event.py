from datetime import datetime, timezone
from enum import Enum

from pydantic import Field, field_validator

from app.schemas.base import StrictApiModel


NON_BLANK_PATTERN = r"\S"


class SafetyEventType(str, Enum):
    OBSTACLE_DETECTED = "OBSTACLE_DETECTED"
    BUS_APPROACHING = "BUS_APPROACHING"
    BEACON_NEAR = "BEACON_NEAR"
    USER_OFF_ROUTE = "USER_OFF_ROUTE"
    CROSSWALK_RISK = "CROSSWALK_RISK"


class SafetyEventCreate(StrictApiModel):
    eventType: SafetyEventType
    source: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    userId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    stopId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    routeId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    confidence: float | None = Field(default=None, ge=0, le=1)
    message: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    metadata: dict[str, str] = Field(default_factory=dict)
    timestamp: datetime | None = None

    @field_validator("timestamp")
    @classmethod
    def timestamp_must_be_timezone_aware(cls, value: datetime | None) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("timestamp must include timezone information.")
        return value.astimezone(timezone.utc)


class SafetyEventRecord(StrictApiModel):
    eventId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    eventType: SafetyEventType
    source: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    userId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    stopId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    routeId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    confidence: float | None = Field(default=None, ge=0, le=1)
    message: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    metadata: dict[str, str] = Field(default_factory=dict)
    timestamp: datetime
    createdAt: datetime


class SafetyEventsRecentResponse(StrictApiModel):
    events: list[SafetyEventRecord]
