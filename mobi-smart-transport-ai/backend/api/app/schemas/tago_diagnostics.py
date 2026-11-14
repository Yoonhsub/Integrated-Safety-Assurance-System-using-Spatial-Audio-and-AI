"""Read-only TAGO diagnostics; fetch time is not observation time."""
from datetime import datetime
from typing import Literal
from pydantic import Field
from app.schemas.base import StrictApiModel

class TagoArrivalRecord(StrictApiModel):
    routeId: str | None = None
    routeNo: str | None = None
    arrivalSeconds: int | None = Field(default=None, ge=0)
    remainingStops: int | None = Field(default=None, ge=0)
    vehicleType: str | None = None
    observedAt: None = None

class TagoLocationRecord(StrictApiModel):
    busId: str | None = None
    nodeId: str | None = None
    nodeName: str | None = None
    positionType: Literal["LAST_REPORTED_STOP"] = "LAST_REPORTED_STOP"
    observedAt: None = None

class TagoDiagnosticResponse(StrictApiModel):
    source: Literal["PUBLIC_API", "ERROR"]
    status: Literal["SUCCESS", "EMPTY", "ERROR"]
    provider: Literal["TAGO"] = "TAGO"
    cityCode: str
    stopId: str | None = None
    routeId: str | None = None
    records: list[TagoArrivalRecord | TagoLocationRecord] = Field(default_factory=list)
    fetchedAt: datetime | None = None
    observedAt: None = None
    errorCode: Literal["SERVICE_KEY_MISSING", "UPSTREAM_TIMEOUT", "UPSTREAM_UNAVAILABLE", "PROVIDER_REJECTED", "MALFORMED_RESPONSE"] | None = None
    totalCount: int | None = None
    truncated: bool = False
    fallbackUsed: Literal[False] = False
