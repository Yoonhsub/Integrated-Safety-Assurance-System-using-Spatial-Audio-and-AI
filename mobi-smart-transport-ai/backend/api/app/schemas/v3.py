from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any
from uuid import uuid4

from pydantic import Field

from app.schemas.base import StrictApiModel


NON_BLANK_PATTERN = r"\S"


class GuidanceState(str, Enum):
    IDLE = "IDLE"
    ROUTE_RECOMMENDED = "ROUTE_RECOMMENDED"
    ROUTE_SELECTED = "ROUTE_SELECTED"
    NAVIGATING_TO_STOP = "NAVIGATING_TO_STOP"
    ARRIVED_AT_STOP = "ARRIVED_AT_STOP"
    WAITING_FOR_BUS = "WAITING_FOR_BUS"
    BOARDING_CONFIRMATION = "BOARDING_CONFIRMATION"
    BOARDED = "BOARDED"
    MISSED_BUS = "MISSED_BUS"
    REPLAN_NEXT_BUS = "REPLAN_NEXT_BUS"


class CueType(str, Enum):
    NONE = "NONE"
    TARGET_BUS_FAR = "TARGET_BUS_FAR"
    TARGET_BUS_MID = "TARGET_BUS_MID"
    TARGET_BUS_NEAR = "TARGET_BUS_NEAR"
    WRONG_BUS_NEAR = "WRONG_BUS_NEAR"
    GEOFENCE_WARNING = "GEOFENCE_WARNING"
    DANGER = "DANGER"


class TtsMode(str, Enum):
    GEMINI_OPTIONAL = "GEMINI_OPTIONAL"
    LOCAL_TTS = "LOCAL_TTS"
    SAFETY_LOCAL = "SAFETY_LOCAL"
    NONE = "NONE"


class FallbackSource(str, Enum):
    PUBLIC_API = "PUBLIC_API"
    CACHE = "CACHE"
    GEMINI = "GEMINI"
    MOCK = "MOCK"
    ERROR = "ERROR"


class AgentIntent(str, Enum):
    WAKE_ONLY = "WAKE_ONLY"
    FIND_ROUTE = "FIND_ROUTE"
    QUERY_ARRIVAL = "QUERY_ARRIVAL"
    SELECT_ARRIVAL = "SELECT_ARRIVAL"
    ASK_CAN_BOARD_CURRENT_BUS = "ASK_CAN_BOARD_CURRENT_BUS"
    REPORT_MISSED_BUS = "REPORT_MISSED_BUS"
    CORRECT_DESTINATION = "CORRECT_DESTINATION"
    CHANGE_DESTINATION = "CHANGE_DESTINATION"
    UNKNOWN = "UNKNOWN"


class BeaconDecision(str, Enum):
    NO_BEACON = "NO_BEACON"
    TARGET_BUS_FAR = "TARGET_BUS_FAR"
    TARGET_BUS_MID = "TARGET_BUS_MID"
    TARGET_BUS_NEAR = "TARGET_BUS_NEAR"
    WRONG_BUS_NEAR = "WRONG_BUS_NEAR"


class V3Cue(StrictApiModel):
    type: CueType = CueType.NONE
    ttsMode: TtsMode = TtsMode.NONE
    shouldVibrate: bool = False
    shouldBeep: bool = False
    message: str | None = None


class GuidanceSessionCreateRequest(StrictApiModel):
    sessionId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    wakeWord: str = Field(default="자비스", min_length=1, pattern=NON_BLANK_PATTERN)


class GuidanceSessionState(StrictApiModel):
    sessionId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    state: GuidanceState
    wakeWord: str
    selectedDestination: str | None = None
    selectedRouteNo: str | None = None
    selectedRouteId: str | None = None
    selectedStopId: str | None = None
    selectedStopName: str | None = None
    targetBusId: str | None = None
    geofenceArmed: bool = False
    lastDecision: BeaconDecision | None = None
    nearestBeacon: dict[str, Any] | None = None
    targetBus: dict[str, Any] | None = None
    updatedAt: datetime


class GuidanceEventRequest(StrictApiModel):
    sessionId: str = Field(default="demo-session", min_length=1, pattern=NON_BLANK_PATTERN)
    event: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    payload: dict[str, Any] = Field(default_factory=dict)


class AgentConverseRequest(StrictApiModel):
    utterance: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    sessionId: str = Field(default="demo-session", min_length=1, pattern=NON_BLANK_PATTERN)
    wakeWord: str = Field(default="자비스", min_length=1, pattern=NON_BLANK_PATTERN)


class AgentConverseResponse(StrictApiModel):
    sessionId: str
    intent: AgentIntent
    state: GuidanceState
    message: str
    ttsMode: TtsMode
    cue: V3Cue = Field(default_factory=V3Cue)
    usedGemini: bool = False
    fallbackSource: FallbackSource = FallbackSource.MOCK


class AgentTtsRequest(StrictApiModel):
    text: str = Field(min_length=1, max_length=500, pattern=NON_BLANK_PATTERN)


class RouteRecommendation(StrictApiModel):
    destination: str
    stopId: str
    stopName: str
    routeNo: str
    routeId: str
    confidence: float = Field(ge=0, le=1)
    fallbackSource: FallbackSource = FallbackSource.MOCK


class RouteRecommendResponse(StrictApiModel):
    recommendations: list[RouteRecommendation]
    fallbackSource: FallbackSource = FallbackSource.MOCK
    usedGemini: bool = False
    planningModel: str | None = None
    planningSummary: str | None = None
    planningDataSource: FallbackSource | None = None
    mapsGrounded: bool = False
    mapsEvidence: list["MapsGroundingEvidence"] = Field(default_factory=list)
    stopEvidence: "PublicBusStopEvidence | None" = None
    evidence: "RoutePlanningEvidence | None" = None


class V3BusArrival(StrictApiModel):
    busId: str | None = None
    routeNo: str
    routeId: str | None = None
    stopId: str
    arrivalMinutes: int = Field(ge=0)
    remainingStops: int | None = Field(default=None, ge=0)
    lowFloor: bool | None = None
    congestion: str | None = None


class RoutePlanningEvidence(StrictApiModel):
    source: FallbackSource
    stopId: str
    stopName: str
    routeNo: str
    arrivals: list[V3BusArrival]


class PublicBusStopEvidence(StrictApiModel):
    source: FallbackSource = FallbackSource.PUBLIC_API
    datasetName: str
    endpoint: str
    serviceId: str
    stopName: str
    longitude: float
    latitude: float
    fetchedAt: datetime
    totalCount: int = Field(ge=0)


class MapsGroundingEvidence(StrictApiModel):
    title: str
    uri: str
    placeId: str | None = None


class V3BusArrivalsResponse(StrictApiModel):
    stopId: str
    routeNo: str | None = None
    arrivals: list[V3BusArrival]
    fallbackSource: FallbackSource = FallbackSource.MOCK


class MockGeofenceRequest(StrictApiModel):
    sessionId: str = Field(default="demo-session", min_length=1, pattern=NON_BLANK_PATTERN)
    event: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)


class MockGeofenceResponse(StrictApiModel):
    sessionId: str
    state: GuidanceState
    geofenceArmed: bool
    cue: V3Cue
    message: str


class BeaconSignal(StrictApiModel):
    busId: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    routeNo: str | None = None
    rssi: int | None = None
    distanceMeters: float | None = Field(default=None, ge=0)


class MockBeaconsRequest(StrictApiModel):
    sessionId: str = Field(default="demo-session", min_length=1, pattern=NON_BLANK_PATTERN)
    targetBusId: str | None = None
    targetRouteNo: str | None = None
    beacons: list[BeaconSignal] = Field(default_factory=list)


class BeaconDecisionResponse(StrictApiModel):
    sessionId: str
    decision: BeaconDecision
    nearestBeacon: BeaconSignal | None = None
    targetBus: BeaconSignal | None = None
    cue: V3Cue
    message: str


class MockBusEventRequest(StrictApiModel):
    sessionId: str = Field(default="demo-session", min_length=1, pattern=NON_BLANK_PATTERN)
    event: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)


def new_session_id() -> str:
    return f"v3-{uuid4().hex}"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)
