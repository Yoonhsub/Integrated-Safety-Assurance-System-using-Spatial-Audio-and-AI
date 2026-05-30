from __future__ import annotations

from enum import Enum
from pydantic import BaseModel


class BeaconDecision(str, Enum):
    NO_BEACON = "NO_BEACON"
    TARGET_BUS_FAR = "TARGET_BUS_FAR"
    TARGET_BUS_MID = "TARGET_BUS_MID"
    TARGET_BUS_NEAR = "TARGET_BUS_NEAR"
    WRONG_BUS_NEAR = "WRONG_BUS_NEAR"
    MULTIPLE_BUSES_TARGET_NOT_NEAREST = "MULTIPLE_BUSES_TARGET_NOT_NEAREST"
    TARGET_BUS_NOT_FOUND = "TARGET_BUS_NOT_FOUND"
    UNKNOWN = "UNKNOWN"


class BeaconEntry(BaseModel):
    busId: str
    routeNo: str
    distanceLevel: str
    rssi: int = -70
    relativePosition: str = "unknown"


class MockBeaconsRequest(BaseModel):
    sessionId: str = "demo-session-001"
    beacons: list[BeaconEntry]


class BeaconCue(BaseModel):
    type: str
    beepPattern: str
    vibrationPattern: str


class BeaconDecisionResponse(BaseModel):
    decision: BeaconDecision
    message: str
    ttsMode: str = "SAFETY_LOCAL"
    cue: BeaconCue | None = None
