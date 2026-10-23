"""Read-only collector observations; never evidence of boarding eligibility."""
from datetime import datetime
from typing import Literal

from app.schemas.base import StrictApiModel
from app.schemas.v3 import BeaconProximity, BeaconSource


class BeaconObservation(StrictApiModel):
    beaconId: str
    deviceId: str
    source: BeaconSource
    observedAt: datetime
    rssi: int
    distanceMeters: float | None
    proximity: BeaconProximity
    validForSeconds: float
    configuredBusId: str | None = None
    configuredRouteNo: str | None = None
    mappingRegistered: bool = False
    vehicleIdentityVerified: Literal[False] = False
    guidanceEligible: Literal[False] = False


class BeaconSessionObservations(StrictApiModel):
    sessionId: str
    status: Literal["AVAILABLE", "EMPTY"]
    message: str = "비콘 수신 관찰 정보입니다. 차량 확인이나 승차 허용을 의미하지 않습니다."
    observations: list[BeaconObservation]
    guidanceEligible: Literal[False] = False
    shouldSpeak: Literal[False] = False
    shouldPlaySpatialCue: Literal[False] = False
