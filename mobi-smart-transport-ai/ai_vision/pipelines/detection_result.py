"""Python representation of the shared VisionDetectionResult contract."""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any


class DetectionStatus(str, Enum):
    OK = "ok"
    UNAVAILABLE = "unavailable"
    ERROR = "error"


@dataclass(frozen=True)
class BoundingBox:
    x: float
    y: float
    w: float
    h: float

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> BoundingBox:
        return cls(x=value["x"], y=value["y"], w=value["w"], h=value["h"])

    def to_dict(self) -> dict[str, float]:
        return {"x": self.x, "y": self.y, "w": self.w, "h": self.h}


@dataclass(frozen=True)
class Detection:
    class_id: str
    class_name: str
    confidence: float
    bbox: BoundingBox

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> Detection:
        return cls(
            class_id=value["classId"],
            class_name=value["className"],
            confidence=value["confidence"],
            bbox=BoundingBox.from_dict(value["bbox"]),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "classId": self.class_id,
            "className": self.class_name,
            "confidence": self.confidence,
            "bbox": self.bbox.to_dict(),
        }


@dataclass(frozen=True)
class ImageSize:
    width: int
    height: int

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> ImageSize:
        return cls(width=value["width"], height=value["height"])

    def to_dict(self) -> dict[str, int]:
        return {"width": self.width, "height": self.height}


@dataclass(frozen=True)
class ModelInfo:
    provider: str
    name: str
    version: str | None = None
    identifier: str | None = None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> ModelInfo:
        return cls(
            provider=value["provider"],
            name=value["name"],
            version=value.get("version"),
            identifier=value.get("identifier"),
        )

    def to_dict(self) -> dict[str, str]:
        value = {"provider": self.provider, "name": self.name}
        if self.version is not None:
            value["version"] = self.version
        if self.identifier is not None:
            value["identifier"] = self.identifier
        return value


@dataclass(frozen=True)
class DetectionError:
    code: str
    message: str

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> DetectionError:
        return cls(code=value["code"], message=value["message"])

    def to_dict(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message}


@dataclass(frozen=True)
class DetectionResult:
    schema_version: str
    source: str
    status: DetectionStatus
    detections: tuple[Detection, ...]
    frame_id: str | None = None
    captured_at: str | None = None
    image_size: ImageSize | None = None
    model_info: ModelInfo | None = None
    error: DetectionError | None = None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> DetectionResult:
        """Convert a schema-validated JSON object to the typed representation."""
        return cls(
            schema_version=value["schemaVersion"],
            source=value["source"],
            status=DetectionStatus(value["status"]),
            detections=tuple(Detection.from_dict(item) for item in value["detections"]),
            frame_id=value.get("frameId"),
            captured_at=value.get("capturedAt"),
            image_size=(
                ImageSize.from_dict(value["imageSize"])
                if "imageSize" in value
                else None
            ),
            model_info=(
                ModelInfo.from_dict(value["modelInfo"])
                if "modelInfo" in value
                else None
            ),
            error=(DetectionError.from_dict(value["error"]) if "error" in value else None),
        )

    def to_dict(self) -> dict[str, Any]:
        """Serialize using the shared contract's camelCase field names."""
        value: dict[str, Any] = {
            "schemaVersion": self.schema_version,
            "source": self.source,
            "status": self.status.value,
            "detections": [detection.to_dict() for detection in self.detections],
        }
        if self.frame_id is not None:
            value["frameId"] = self.frame_id
        if self.captured_at is not None:
            value["capturedAt"] = self.captured_at
        if self.image_size is not None:
            value["imageSize"] = self.image_size.to_dict()
        if self.model_info is not None:
            value["modelInfo"] = self.model_info.to_dict()
        if self.error is not None:
            value["error"] = self.error.to_dict()
        return value
