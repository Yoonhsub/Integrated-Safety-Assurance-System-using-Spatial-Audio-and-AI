"""HTTP contracts for AI Vision interpretation ingestion."""
from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator, model_validator

from app.schemas.base import StrictApiModel
from app.schemas.safety_event import SafetyEventRecord


NON_BLANK_PATTERN = r"\S"


class AiVisionInterpretationStatus(str, Enum):
    EVENT = "event"
    NO_EVENT = "no_event"
    UNAVAILABLE = "unavailable"
    ERROR = "error"


class AiVisionRiskLevel(str, Enum):
    INFO = "info"
    WARN = "warn"
    DANGER = "danger"


class AiVisionPrimaryClass(str, Enum):
    BUS = "bus"
    BUS_DOOR = "bus_door"
    BUS_STOP = "bus_stop"
    ROADWAY = "roadway"
    SIDEWALK = "sidewalk"
    OBSTACLE = "obstacle"
    TACTILE_PAVING = "tactile_paving"


class AiVisionReason(str, Enum):
    BUS_STOP_RECOGNIZED = "bus_stop_recognized"
    APPROACHING_BUS = "approaching_bus"
    BUS_DOOR_VISIBLE = "bus_door_visible"
    OFF_SIDEWALK = "off_sidewalk"
    OBSTACLE_AHEAD = "obstacle_ahead"
    TACTILE_PAVING_LOST = "tactile_paving_lost"


_REASON_PRIMARY_CLASS = {
    AiVisionReason.BUS_STOP_RECOGNIZED: AiVisionPrimaryClass.BUS_STOP,
    AiVisionReason.APPROACHING_BUS: AiVisionPrimaryClass.BUS,
    AiVisionReason.BUS_DOOR_VISIBLE: AiVisionPrimaryClass.BUS_DOOR,
    AiVisionReason.OFF_SIDEWALK: AiVisionPrimaryClass.ROADWAY,
    AiVisionReason.OBSTACLE_AHEAD: AiVisionPrimaryClass.OBSTACLE,
    AiVisionReason.TACTILE_PAVING_LOST: AiVisionPrimaryClass.TACTILE_PAVING,
}


class AiVisionModelInfo(StrictApiModel):
    provider: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    name: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    version: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)

    @model_validator(mode="after")
    def optional_version_must_be_omitted_when_missing(self) -> AiVisionModelInfo:
        if "version" in self.model_fields_set and self.version is None:
            raise ValueError("modelInfo.version must be omitted when unavailable.")
        return self


class AiVisionInferenceError(StrictApiModel):
    code: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    message: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)


class AiVisionInterpretationIngestRequest(StrictApiModel):
    schemaVersion: Literal["1.0.0"]
    status: AiVisionInterpretationStatus
    source: str = Field(min_length=1, pattern=NON_BLANK_PATTERN)
    eventId: UUID | None = None
    frameId: UUID | None = None
    capturedAt: datetime | None = None
    riskLevel: AiVisionRiskLevel | None = None
    reason: AiVisionReason | None = None
    primaryClass: AiVisionPrimaryClass | None = None
    confidence: float | None = Field(default=None, ge=0, le=1)
    message: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)
    modelInfo: AiVisionModelInfo | None = None
    error: AiVisionInferenceError | None = None

    @field_validator("capturedAt")
    @classmethod
    def captured_at_must_be_timezone_aware(
        cls,
        value: datetime | None,
    ) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("capturedAt must include timezone information.")
        return value.astimezone(timezone.utc)

    @model_validator(mode="after")
    def validate_status_fields(self) -> AiVisionInterpretationIngestRequest:
        optional_fields = (
            "eventId",
            "frameId",
            "capturedAt",
            "riskLevel",
            "reason",
            "primaryClass",
            "confidence",
            "message",
            "modelInfo",
            "error",
        )
        explicit_nulls = [
            name for name in optional_fields
            if name in self.model_fields_set and getattr(self, name) is None
        ]
        if explicit_nulls:
            raise ValueError(
                "Optional transport fields must be omitted instead of set to null: "
                + ", ".join(explicit_nulls)
            )
        event_fields = (
            self.eventId,
            self.riskLevel,
            self.reason,
            self.primaryClass,
            self.confidence,
            self.message,
            self.modelInfo,
        )
        if self.status is AiVisionInterpretationStatus.EVENT:
            if not self.frameId or not self.capturedAt or any(v is None for v in event_fields):
                raise ValueError(
                    "event status requires eventId, frameId, capturedAt, riskLevel, reason, "
                    "primaryClass, confidence, message, and modelInfo."
                )
            if self.error is not None:
                raise ValueError("event status cannot contain an inference error.")
            if _REASON_PRIMARY_CLASS[self.reason] is not self.primaryClass:
                raise ValueError("reason and primaryClass do not match the vision taxonomy.")
            return self

        if any(value is not None for value in event_fields):
            raise ValueError("non-event status cannot contain Safety Event fields.")
        if self.status is AiVisionInterpretationStatus.NO_EVENT:
            if self.frameId is None or self.capturedAt is None:
                raise ValueError("no_event status requires frameId and capturedAt.")
            if self.error is not None:
                raise ValueError("no_event status cannot contain an inference error.")
        elif self.error is None:
            raise ValueError("unavailable/error status requires error details.")
        return self


class AiVisionInterpretationIngestResponse(StrictApiModel):
    status: AiVisionInterpretationStatus
    stored: bool
    safetyEvent: SafetyEventRecord | None

    @model_validator(mode="after")
    def validate_storage_outcome(self) -> AiVisionInterpretationIngestResponse:
        if self.status is AiVisionInterpretationStatus.EVENT:
            if not self.stored or self.safetyEvent is None:
                raise ValueError("event status must return a stored Safety Event.")
        elif self.stored or self.safetyEvent is not None:
            raise ValueError("non-event status must not return a stored Safety Event.")
        return self
