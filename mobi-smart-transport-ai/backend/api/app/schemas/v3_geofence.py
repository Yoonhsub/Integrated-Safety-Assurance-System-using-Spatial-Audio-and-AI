from __future__ import annotations

from enum import Enum
from pydantic import BaseModel


class V3GeofenceStatus(str, Enum):
    SAFE = "SAFE"
    WARNING = "WARNING"
    DANGER = "DANGER"
    UNKNOWN = "UNKNOWN"


class MockGeofenceRequest(BaseModel):
    sessionId: str = "demo-session-001"
    mockStatus: str


class GeofenceCue(BaseModel):
    type: str
    beepPattern: str
    vibrationPattern: str


class V3GeofenceResponse(BaseModel):
    geofenceStatus: V3GeofenceStatus
    message: str
    shouldSpeak: bool = True
    shouldVibrate: bool = False
    ttsMode: str = "SAFETY_LOCAL"
    cue: GeofenceCue | None = None
