"""Local producer transport; reuse the unmodified DetectionResult JSON Schema."""
import json
import math
from datetime import datetime
from functools import lru_cache
from pathlib import Path
from typing import Any, Literal
from uuid import UUID

from jsonschema import Draft202012Validator, FormatChecker, SchemaError, ValidationError
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.security import auth_error, valid_key

_SCHEMA = Path(__file__).resolve().parents[4] / "packages/shared_contracts/api/vision_detection.response.schema.json"


@lru_cache(maxsize=1)
def detection_validator():
    # Production packaging need not include this local-only contract. Do not
    # break unrelated API startup; a missing validator must fail closed on use.
    try:
        schema = json.loads(_SCHEMA.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
        return Draft202012Validator(schema, format_checker=FormatChecker())
    except (OSError, ValueError, SchemaError):
        raise auth_error(503, "Vision contract validation unavailable") from None


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CameraRegistration(StrictModel):
    producerId: str
    sourceType: Literal["live", "replay"]

    @field_validator("producerId")
    @classmethod
    def producer_key(cls, value: str) -> str:
        if not valid_key(value):
            raise ValueError("Invalid producer identifier")
        return value


class BindingCreate(StrictModel):
    cameraId: str
    sessionId: str = Field(min_length=1, max_length=128)
    ttlSeconds: int = Field(default=900, ge=1, le=3600, strict=True)

    @field_validator("cameraId")
    @classmethod
    def camera_key(cls, value: str) -> str:
        if not valid_key(value):
            raise ValueError("Invalid camera identifier")
        return value


class VisionEnvelope(StrictModel):
    envelopeVersion: Literal["2.0.0"]
    producerId: str = Field(min_length=1, max_length=128)
    cameraId: str = Field(min_length=1, max_length=128)
    sessionId: str = Field(min_length=1, max_length=128)
    bindingId: UUID
    cameraEpoch: UUID
    visionEventId: UUID
    sourceType: Literal["live", "replay"]
    capturedAt: datetime
    captureClock: Literal["unknown", "host_read", "sensor"] = "unknown"
    frameIndex: int = Field(ge=0, strict=True)
    detectionResult: dict[str, Any]

    @field_validator("capturedAt", mode="before")
    @classmethod
    def timestamp_text(cls, value):
        if not isinstance(value, (str, datetime)):
            raise ValueError("capturedAt must be an ISO timestamp, not a numeric epoch")
        return value

    @field_validator("capturedAt")
    @classmethod
    def aware_time(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("capturedAt must include timezone")
        return value

    @field_validator("detectionResult")
    @classmethod
    def detection_contract(cls, value: dict) -> dict:
        try:
            detection_validator().validate(value)
        except ValidationError:
            raise ValueError("Invalid DetectionResult contract") from None
        for detection in value["detections"]:
            box = detection["bbox"]
            if not all(math.isfinite(n) for n in [detection["confidence"], *box.values()]):
                raise ValueError("Detection numbers must be finite")
            if box["x"] + box["w"] > 1.000000001 or box["y"] + box["h"] > 1.000000001:
                raise ValueError("Bounding box exceeds normalized image boundary")
        return value

    @model_validator(mode="after")
    def consistent_metadata(self):
        timestamp = self.detectionResult.get("capturedAt")
        if timestamp is not None and datetime.fromisoformat(timestamp.replace("Z", "+00:00")) != self.capturedAt:
            raise ValueError("Conflicting capture timestamps")
        expected_source = "webcam" if self.sourceType == "live" else "video_file"
        if self.detectionResult["source"] != expected_source:
            raise ValueError("Input source disagrees with capture mode")
        return self


class VisionReceipt(StrictModel):
    visionEventId: UUID
    bindingId: UUID
    receivedAt: datetime
    accepted: Literal[True] = True
    stored: Literal[False] = False
    guidanceEligible: Literal[False] = False
    freshnessVerified: Literal[False] = False
    mode: Literal["local-validation-only"] = "local-validation-only"


class VisionCameraState(StrictModel):
    cameraId: str
    bindingStatus: Literal["inactive", "active", "invalidated", "expired"]
    connectionStatus: Literal["closed", "waiting", "connected", "lost", "replay"]
    observationStatus: Literal["unknown", "observed", "no_detection", "unavailable", "error", "expired", "ineligible"]
    sourceType: Literal["live", "replay"]
    cameraEpoch: UUID | None
    lastFrameIndex: int | None
    lastCapturedAt: datetime | None
    lastReceivedAt: datetime | None
    captureClock: Literal["unknown", "host_read", "sensor"]
    freshnessVerified: Literal[False] = False
    guidanceEligible: Literal[False] = False
