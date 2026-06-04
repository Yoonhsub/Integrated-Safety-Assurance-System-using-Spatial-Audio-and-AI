from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any, Literal
from uuid import uuid4

from pydantic import Field, model_validator

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
    END_CONVERSATION = "END_CONVERSATION"
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
    selectedPlanId: str | None = None
    pendingDestinationCandidates: list[str] = Field(default_factory=list)
    originLocation: dict[str, float] | None = None
    nearbyBoardingStops: list[dict[str, Any]] = Field(default_factory=list)
    nearbyAlightingStops: list[dict[str, Any]] = Field(default_factory=list)
    recommendedPlan: dict[str, Any] | None = None
    alternativePlans: list[dict[str, Any]] = Field(default_factory=list)
    selectedPlan: dict[str, Any] | None = None
    currentLegIndex: int = Field(default=0, ge=0)
    pendingQuestion: str | None = None
    pendingResolutionStatus: str | None = None
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
    # 요청별 데이터 모드("live"|"mock"). 지정 시 전역 PUBLIC_DATA_USE_MOCK보다 우선한다.
    mode: Literal["mock", "live"] | None = None
    # 현재 위치가 들어오면 에이전트 대화 안에서 바로 RoutePlan까지 계산한다.
    originLat: float | None = Field(default=None, ge=-90, le=90)
    originLng: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def validate_origin_pair(self) -> "AgentConverseRequest":
        if (self.originLat is None) != (self.originLng is None):
            raise ValueError("originLat and originLng must be provided together.")
        return self


class AgentTraceEvent(StrictApiModel):
    id: str
    step: int = Field(ge=1)
    type: str
    title: str
    status: Literal["PENDING", "RUNNING", "DONE", "FAILED", "SKIPPED"]
    summary: str
    provider: str | None = None
    operation: str | None = None
    safePayload: dict[str, Any] = Field(default_factory=dict)
    startedAt: datetime | None = None
    finishedAt: datetime | None = None
    durationMs: int | None = Field(default=None, ge=0)
    warning: str | None = None


class AgentConverseResponse(StrictApiModel):
    sessionId: str
    intent: AgentIntent
    state: GuidanceState
    message: str
    ttsMode: TtsMode
    cue: V3Cue = Field(default_factory=V3Cue)
    usedGemini: bool = False
    fallbackSource: FallbackSource = FallbackSource.MOCK
    routePlan: "RoutePlanResponse | None" = None
    trace: list[AgentTraceEvent] = Field(default_factory=list)
    traceId: str | None = None


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


class DestinationResolveStatus(str, Enum):
    RESOLVED = "RESOLVED"
    NEEDS_CONFIRMATION = "NEEDS_CONFIRMATION"
    NEEDS_CHOICE = "NEEDS_CHOICE"
    NOT_FOUND = "NOT_FOUND"


class DestinationCandidateType(str, Enum):
    STOP = "STOP"
    PLACE = "PLACE"
    ADDRESS = "ADDRESS"


class NearbyStopCandidate(StrictApiModel):
    stopId: str
    stopName: str
    latitude: float
    longitude: float
    distanceMeters: float | None = Field(default=None, ge=0)
    source: FallbackSource = FallbackSource.MOCK
    directionHint: str | None = None
    sideHint: str | None = None
    visionRequiredForSideHint: bool = False
    crossStreetHint: str | None = None


class DestinationCandidate(StrictApiModel):
    name: str
    type: DestinationCandidateType
    confidence: float = Field(ge=0, le=1)
    latitude: float | None = None
    longitude: float | None = None
    address: str | None = None
    stopId: str | None = None
    source: FallbackSource = FallbackSource.MOCK


class DestinationResolveResponse(StrictApiModel):
    status: DestinationResolveStatus
    heardText: str
    normalizedText: str
    topCandidate: DestinationCandidate | None = None
    candidates: list[DestinationCandidate] = Field(default_factory=list)
    question: str | None = None
    originStops: list[NearbyStopCandidate] = Field(default_factory=list)
    destinationStops: list[NearbyStopCandidate] = Field(default_factory=list)
    fallbackSource: FallbackSource = FallbackSource.MOCK


class RoutePlanStatus(str, Enum):
    RESOLVED = "RESOLVED"
    ALREADY_NEAR_DESTINATION = "ALREADY_NEAR_DESTINATION"
    NEEDS_CONFIRMATION = "NEEDS_CONFIRMATION"
    NEEDS_CHOICE = "NEEDS_CHOICE"
    NOT_FOUND = "NOT_FOUND"
    NO_ROUTE = "NO_ROUTE"
    ERROR = "ERROR"


class RoutePlanReadiness(str, Enum):
    READY = "READY"
    ALREADY_NEAR_DESTINATION = "ALREADY_NEAR_DESTINATION"
    NEEDS_CONFIRMATION = "NEEDS_CONFIRMATION"
    NEEDS_CHOICE = "NEEDS_CHOICE"
    NOT_FOUND = "NOT_FOUND"
    NO_ROUTE = "NO_ROUTE"
    ERROR = "ERROR"


class RoutePlanType(str, Enum):
    DIRECT = "DIRECT"
    ONE_TRANSFER = "ONE_TRANSFER"


class RoutePlanSource(str, Enum):
    LOCAL_FALLBACK = "LOCAL_FALLBACK"
    ODSAY = "ODSAY"
    ODSAY_ENRICHED = "ODSAY_ENRICHED"


class RoutePlanVerificationStatus(str, Enum):
    LOCAL_ONLY = "LOCAL_ONLY"
    VERIFIED_WITH_TAGO = "VERIFIED_WITH_TAGO"
    PARTIAL = "PARTIAL"
    ODSAY_ONLY = "ODSAY_ONLY"


class RoutePlanLegMode(str, Enum):
    WALK = "WALK"
    BUS = "BUS"
    SUBWAY = "SUBWAY"


class RoutePlanStop(StrictApiModel):
    stopId: str
    stopName: str
    nodeId: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    distanceMeters: float | None = Field(default=None, ge=0)
    order: int | None = Field(default=None, ge=0)
    directionHint: str | None = None
    sideHint: str | None = None
    visionRequiredForSideHint: bool = False
    crossStreetHint: str | None = None


class RoutePlanServiceStatus(StrictApiModel):
    operatingNow: bool
    reason: str
    message: str
    nextServiceTime: str | None = None
    nextServiceLabel: str | None = None
    scheduleSource: str


class RoutePlanSegment(StrictApiModel):
    routeNo: str
    routeId: str
    source: str = "LOCAL"
    providerRouteId: str | None = None
    boardingStopNodeId: str | None = None
    alightingStopNodeId: str | None = None
    boardStop: RoutePlanStop
    alightStop: RoutePlanStop
    stopCount: int = Field(ge=0)
    directionHint: str | None = None
    arrivals: list[V3BusArrival] = Field(default_factory=list)
    arrivalSource: FallbackSource = FallbackSource.MOCK
    arrivalUnknown: bool = False
    estimatedMinutes: int | None = Field(default=None, ge=0)
    serviceStatus: RoutePlanServiceStatus | None = None


class RoutePlanLeg(StrictApiModel):
    mode: RoutePlanLegMode
    routeNo: str | None = None
    providerRouteId: str | None = None
    routeId: str | None = None
    boardingStopName: str | None = None
    boardingStopId: str | None = None
    boardingStopNodeId: str | None = None
    alightingStopName: str | None = None
    alightingStopId: str | None = None
    alightingStopNodeId: str | None = None
    directionHint: str | None = None
    estimatedMinutes: int | None = Field(default=None, ge=0)
    source: str


class RoutePlanArrivalSummary(StrictApiModel):
    arrivalMinutes: int = Field(ge=0)
    remainingStops: int | None = Field(default=None, ge=0)
    source: FallbackSource


class RoutePlanCandidate(StrictApiModel):
    planId: str
    type: RoutePlanType
    destinationName: str
    summary: str
    boardingInstruction: str
    transferCount: int = Field(ge=0)
    totalBusStopCount: int = Field(ge=0)
    estimatedWalkMeters: float = Field(ge=0)
    accessibilityScore: float = Field(ge=0, le=1)
    simplicityScore: float = Field(ge=0, le=1)
    score: float = Field(ge=0, le=100)
    totalEstimatedMinutes: int | None = Field(default=None, ge=0)
    recommendedReason: str | None = None
    rankingEvidence: list[str] = Field(default_factory=list)
    segments: list[RoutePlanSegment]
    fallbackSource: FallbackSource = FallbackSource.MOCK
    planSource: RoutePlanSource = RoutePlanSource.LOCAL_FALLBACK
    provider: str = "LOCAL"
    verificationStatus: RoutePlanVerificationStatus = RoutePlanVerificationStatus.LOCAL_ONLY
    warnings: list[str] = Field(default_factory=list)
    rawProviderEvidence: dict[str, Any] = Field(default_factory=dict)
    legs: list[RoutePlanLeg] = Field(default_factory=list)
    arrival: RoutePlanArrivalSummary | None = None
    notRecommendedReason: str | None = None
    serviceStatus: RoutePlanServiceStatus | None = None


class RoutePlanResponse(StrictApiModel):
    status: RoutePlanStatus
    readiness: RoutePlanReadiness = RoutePlanReadiness.ERROR
    heardText: str
    destination: DestinationResolveResponse
    plans: list[RoutePlanCandidate] = Field(default_factory=list)
    recommendedPlan: RoutePlanCandidate | None = None
    alternatives: list[RoutePlanCandidate] = Field(default_factory=list)
    agentMessage: str | None = None
    question: str | None = None
    fallbackSource: FallbackSource = FallbackSource.MOCK
    warnings: list[str] = Field(default_factory=list)
    rawProviderEvidence: dict[str, Any] = Field(default_factory=dict)


class RoutePlanRequest(StrictApiModel):
    destinationText: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    originLat: float | None = Field(default=None, ge=-90, le=90)
    originLng: float | None = Field(default=None, ge=-180, le=180)
    mode: Literal["mock", "live"] | None = None

    @model_validator(mode="after")
    def validate_origin_pair(self) -> "RoutePlanRequest":
        if (self.originLat is None) != (self.originLng is None):
            raise ValueError("originLat and originLng must be provided together.")
        return self


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
    arrivalSeconds: int | None = Field(default=None, ge=0)
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
    serviceStatus: RoutePlanServiceStatus | None = None


class V3LiveRouteMarker(StrictApiModel):
    type: Literal["USER", "BOARD_STOP", "ALIGHT_STOP", "DESTINATION", "BUS"]
    label: str
    latitude: float
    longitude: float
    busId: str | None = None


class V3BusPosition(StrictApiModel):
    busId: str | None = None
    routeNo: str
    routeId: str
    nodeId: str | None = None
    nodeName: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    source: FallbackSource = FallbackSource.PUBLIC_API


class V3LiveRouteStatusResponse(StrictApiModel):
    routeNo: str
    routeId: str
    boardStopId: str
    alightStopId: str
    markers: list[V3LiveRouteMarker] = Field(default_factory=list)
    arrivals: list[V3BusArrival] = Field(default_factory=list)
    busPositions: list[V3BusPosition] = Field(default_factory=list)
    serviceStatus: RoutePlanServiceStatus
    warnings: list[str] = Field(default_factory=list)
    updatedAt: datetime
    fallbackSource: FallbackSource = FallbackSource.ERROR


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
