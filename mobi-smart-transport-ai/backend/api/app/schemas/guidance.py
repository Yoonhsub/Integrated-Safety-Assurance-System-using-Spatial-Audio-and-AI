from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


class GuidanceState(str, Enum):
    IDLE = "IDLE"
    DESTINATION_SET = "DESTINATION_SET"
    ROUTE_RECOMMENDED = "ROUTE_RECOMMENDED"
    ROUTE_SELECTED = "ROUTE_SELECTED"
    NAVIGATING_TO_STOP = "NAVIGATING_TO_STOP"
    ARRIVED_AT_STOP = "ARRIVED_AT_STOP"
    WAITING_FOR_BUS = "WAITING_FOR_BUS"
    BUS_APPROACHING = "BUS_APPROACHING"
    BOARDING_CONFIRMATION = "BOARDING_CONFIRMATION"
    BOARDED = "BOARDED"
    MISSED_BUS = "MISSED_BUS"
    REPLAN_NEXT_BUS = "REPLAN_NEXT_BUS"


ALLOWED_TRANSITIONS: dict[GuidanceState, set[GuidanceState]] = {
    GuidanceState.IDLE: {GuidanceState.DESTINATION_SET},
    GuidanceState.DESTINATION_SET: {GuidanceState.ROUTE_RECOMMENDED},
    GuidanceState.ROUTE_RECOMMENDED: {GuidanceState.ROUTE_SELECTED},
    GuidanceState.ROUTE_SELECTED: {GuidanceState.NAVIGATING_TO_STOP},
    GuidanceState.NAVIGATING_TO_STOP: {GuidanceState.ARRIVED_AT_STOP},
    GuidanceState.ARRIVED_AT_STOP: {GuidanceState.WAITING_FOR_BUS},
    GuidanceState.WAITING_FOR_BUS: {GuidanceState.BUS_APPROACHING},
    GuidanceState.BUS_APPROACHING: {GuidanceState.BOARDING_CONFIRMATION},
    GuidanceState.BOARDING_CONFIRMATION: {GuidanceState.BOARDED, GuidanceState.MISSED_BUS},
    GuidanceState.MISSED_BUS: {GuidanceState.REPLAN_NEXT_BUS},
    GuidanceState.REPLAN_NEXT_BUS: {GuidanceState.WAITING_FOR_BUS},
    GuidanceState.BOARDED: set(),
}


class GuidanceSession(BaseModel):
    sessionId: str = "demo-session-001"
    userId: str = "passenger-demo-001"
    guidanceState: GuidanceState = GuidanceState.IDLE
    wakeWord: str = "자비스"
    destination: str | None = None
    selectedStopId: str | None = None
    selectedStopName: str | None = None
    selectedRouteNo: str | None = None
    selectedRouteId: str | None = None
    targetBusId: str | None = None
    targetArrivalMinutes: int | None = None
    hasArrivedAtStop: bool = False
    geofenceArmed: bool = False
    nearestBeaconId: str | None = None
    nearestRouteNo: str | None = None
    targetRelativePosition: str | None = None
    nearestRelativePosition: str | None = None
    lastDecision: str | None = None
    lastAiIntent: str | None = None
    lastMessage: str | None = None
    lastApi: str | None = None
    fallbackSource: str | None = None


class CreateSessionRequest(BaseModel):
    userId: str | None = None
    wakeWord: str | None = None
    sessionId: str | None = None


class StartGuidanceRequest(BaseModel):
    sessionId: str
    selectedStopId: str
    selectedStopName: str
    selectedRouteNo: str
    targetBusId: str | None = None
    targetArrivalMinutes: int | None = None
    selectedRouteId: str | None = None


class TransitionRequest(BaseModel):
    sessionId: str
    targetState: GuidanceState


class ResetRequest(BaseModel):
    sessionId: str


class BoardingConfirmRequest(BaseModel):
    sessionId: str
    boarded: bool


class BoardingConfirmResponse(BaseModel):
    guidanceState: str
    previousState: str | None = None
    nextRouteNo: str | None = None
    nextArrivalMinutes: int | None = None
    message: str
    shouldSpeak: bool = True
    cue: dict | None = None
    fallbackSource: str | None = None


class BusEventRequest(BaseModel):
    sessionId: str
    event: str


class BusEventResponse(BaseModel):
    guidanceState: str
    message: str
    shouldSpeak: bool = True
