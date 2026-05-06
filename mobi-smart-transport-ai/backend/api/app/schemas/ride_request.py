from datetime import datetime
from enum import Enum
from pydantic import Field, model_validator

from app.schemas.base import StrictApiModel


NON_BLANK_PATTERN = r"\S"


class RideRequestStatus(str, Enum):
    WAITING = "WAITING"
    NOTIFIED = "NOTIFIED"
    ACCEPTED = "ACCEPTED"
    ARRIVED = "ARRIVED"
    COMPLETED = "COMPLETED"
    CANCELLED = "CANCELLED"


class RideRequestCreate(StrictApiModel):
    userId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    stopId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    routeId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    busNo: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    targetDriverId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)

    @model_validator(mode="after")
    def validate_target_driver(self) -> "RideRequestCreate":
        if self.targetDriverId is not None and not self.targetDriverId.strip():
            raise ValueError("targetDriverId는 비어 있지 않은 문자열이어야 합니다.")
        return self


class RideRequestStatusUpdate(StrictApiModel):
    status: RideRequestStatus


class RideRequestRecord(StrictApiModel):
    requestId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    userId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    stopId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    routeId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    busNo: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    targetDriverId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    status: RideRequestStatus
    createdAt: datetime
    updatedAt: datetime | None = None

    @model_validator(mode="after")
    def validate_target_driver(self) -> "RideRequestRecord":
        if self.targetDriverId is not None and not self.targetDriverId.strip():
            raise ValueError("targetDriverId는 비어 있지 않은 문자열이어야 합니다.")
        return self


class DriverRideRequestsResponse(StrictApiModel):
    driverId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    requests: list[RideRequestRecord]
