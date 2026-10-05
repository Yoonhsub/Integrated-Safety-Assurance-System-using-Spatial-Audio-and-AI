"""Deterministic, single-frame interpretation of project vision detections."""
from __future__ import annotations

import json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any
from uuid import NAMESPACE_URL, uuid5

from ai_vision.pipelines.detection_result import (
    BoundingBox,
    Detection,
    DetectionError,
    DetectionResult,
    DetectionStatus,
    ImageSize,
    ModelInfo,
)


_TAXONOMY_PATH = Path(__file__).resolve().parents[1] / "dataset_plan" / "class_taxonomy.json"
# These existing taxonomy reasons can be asserted from one frame alone. The
# remaining reasons require temporal, user-location, or path context.
_SINGLE_FRAME_REASONS = frozenset({"bus_stop_recognized", "bus_door_visible"})
_RISK_ORDER = {"info": 0, "warn": 1, "danger": 2}
_CLASS_PRIORITY_ORDER = {"medium": 0, "high": 1}


class InterpretationStatus(str, Enum):
    EVENT = "event"
    NO_EVENT = "no_event"
    UNAVAILABLE = "unavailable"
    ERROR = "error"


@dataclass(frozen=True)
class SafetyEventDetection:
    """Detection summary using the existing Safety Event fixture field names."""

    class_id: str
    bbox: BoundingBox
    score: float

    @classmethod
    def from_detection(cls, detection: Detection) -> SafetyEventDetection:
        return cls(detection.class_id, detection.bbox, detection.confidence)

    def to_dict(self) -> dict[str, Any]:
        return {
            "classId": self.class_id,
            "bbox": self.bbox.to_dict(),
            "score": self.score,
        }


@dataclass(frozen=True)
class SafetyEvent:
    """AI Vision internal event; intentionally distinct from backend SafetyEventCreate."""

    event_id: str
    frame_id: str
    captured_at: str
    source: str
    risk_level: str
    reason: str
    primary_class: str
    confidence: float
    detections: tuple[SafetyEventDetection, ...]
    message: str
    image_size: ImageSize | None = None
    model_info: ModelInfo | None = None

    def to_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "eventId": self.event_id,
            "frameId": self.frame_id,
            "capturedAt": self.captured_at,
            "source": self.source,
            "riskLevel": self.risk_level,
            "reason": self.reason,
            "primaryClass": self.primary_class,
            "confidence": self.confidence,
            "detections": [item.to_dict() for item in self.detections],
            "message": self.message,
        }
        if self.image_size is not None:
            value["imageSize"] = self.image_size.to_dict()
        if self.model_info is not None:
            value["modelInfo"] = {
                "name": self.model_info.name,
                **({"version": self.model_info.version} if self.model_info.version else {}),
            }
        return value


@dataclass(frozen=True)
class SafetyInterpretation:
    """Interpretation outcome, where no-event differs from unavailable/error."""

    status: InterpretationStatus
    frame_id: str | None
    captured_at: str | None
    source: str
    event: SafetyEvent | None = None
    error: DetectionError | None = None


class SafetyInterpreterConfigurationError(ValueError):
    """The taxonomy is unavailable or malformed."""


class SafetyInterpreterInputError(ValueError):
    """An ostensibly successful result lacks required frame metadata."""


class SafetyInterpreter:
    """Apply taxonomy thresholds and single-frame-safe reason rules."""

    def __init__(self, taxonomy_path: Path | None = None) -> None:
        path = taxonomy_path or _TAXONOMY_PATH
        try:
            self._taxonomy = json.loads(path.read_text(encoding="utf-8"))
            self._classes = {item["id"]: item for item in self._taxonomy["classes"]}
            self._reasons = {item["code"]: item for item in self._taxonomy["reason_codes"]}
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
            raise SafetyInterpreterConfigurationError(
                f"Could not load a valid AI Vision taxonomy from {path}."
            ) from exc

    def interpret(self, result: DetectionResult) -> SafetyInterpretation:
        """Interpret one DetectionResult without inferring absent context."""
        if not isinstance(result, DetectionResult):
            raise SafetyInterpreterInputError("result must be a DetectionResult.")

        status_map = {
            DetectionStatus.UNAVAILABLE: InterpretationStatus.UNAVAILABLE,
            DetectionStatus.ERROR: InterpretationStatus.ERROR,
        }
        if result.status in status_map:
            return SafetyInterpretation(
                status=status_map[result.status],
                frame_id=result.frame_id,
                captured_at=result.captured_at,
                source=result.source,
                error=result.error,
            )

        if not result.frame_id or not result.captured_at or result.model_info is None:
            raise SafetyInterpreterInputError(
                "An ok DetectionResult requires frame_id, captured_at, and model_info."
            )

        accepted: list[tuple[Detection, dict[str, Any]]] = []
        for detection in result.detections:
            class_def = self._classes.get(detection.class_id)
            if class_def is None or not 0.0 <= detection.confidence <= 1.0:
                # Unknown/invalid detector output cannot establish a safety event.
                continue
            if detection.confidence < class_def["detection_threshold"]:
                continue
            accepted.append((detection, class_def))
        accepted.sort(
            key=lambda item: (
                item[0].class_id,
                item[0].bbox.x,
                item[0].bbox.y,
                item[0].bbox.w,
                item[0].bbox.h,
                -item[0].confidence,
            )
        )

        candidates: list[tuple[Detection, dict[str, Any], dict[str, Any]]] = []
        for detection, class_def in accepted:
            for reason_code in class_def.get("related_reasons", []):
                if reason_code not in _SINGLE_FRAME_REASONS:
                    continue
                reason = self._reasons.get(reason_code)
                if reason is not None and reason.get("trigger_primary_class") == detection.class_id:
                    candidates.append((detection, class_def, reason))

        if not candidates:
            return SafetyInterpretation(
                status=InterpretationStatus.NO_EVENT,
                frame_id=result.frame_id,
                captured_at=result.captured_at,
                source=result.source,
            )

        def rank(candidate: tuple[Detection, dict[str, Any], dict[str, Any]]) -> tuple[Any, ...]:
            detection, class_def, reason = candidate
            bbox = detection.bbox
            return (
                -_RISK_ORDER.get(reason["default_risk_level"], -1),
                -_CLASS_PRIORITY_ORDER.get(class_def.get("priority"), -1),
                -detection.confidence,
                detection.class_id,
                bbox.x,
                bbox.y,
                bbox.w,
                bbox.h,
                reason["code"],
            )

        primary, _class_def, reason = min(candidates, key=rank)
        event_id = str(
            uuid5(
                NAMESPACE_URL,
                f"vision-safety-event:{result.frame_id}:{reason['code']}:{primary.class_id}",
            )
        )
        event = SafetyEvent(
            event_id=event_id,
            frame_id=result.frame_id,
            captured_at=result.captured_at,
            source=result.source,
            risk_level=reason["default_risk_level"],
            reason=reason["code"],
            primary_class=primary.class_id,
            confidence=primary.confidence,
            detections=tuple(SafetyEventDetection.from_detection(d) for d, _ in accepted),
            message=reason["ko_message"],
            image_size=result.image_size,
            model_info=result.model_info,
        )
        return SafetyInterpretation(
            status=InterpretationStatus.EVENT,
            frame_id=result.frame_id,
            captured_at=result.captured_at,
            source=result.source,
            event=event,
        )
