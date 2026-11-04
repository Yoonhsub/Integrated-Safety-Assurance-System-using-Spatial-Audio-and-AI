"""AI Vision의 실제 추론 어댑터가 반환할 로컬 결과 계약.

이 모듈은 카메라나 특정 모델 SDK에 의존하지 않는다. YOLO 등 모델 어댑터는
``RawDetection`` 목록을 만들고, 이 모듈은 이를 프로젝트 taxonomy에 맞는
정규화된 ``VisionResult``로 변환한다. 따라서 모델 교체나 mock/live 전환이
Safety Event 계약에 영향을 주지 않는다.
"""

from __future__ import annotations

import json
import math
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


_TAXONOMY_PATH = Path(__file__).resolve().parent.parent / "dataset_plan" / "class_taxonomy.json"


class VisionResultValidationError(ValueError):
    """모델 출력이 AI Vision 로컬 계약을 만족하지 않을 때 발생한다."""


@dataclass(frozen=True)
class ImageSize:
    """추론에 사용한 프레임의 픽셀 크기."""

    width: int
    height: int

    def __post_init__(self) -> None:
        if self.width <= 0 or self.height <= 0:
            raise VisionResultValidationError("image width and height must be positive")


@dataclass(frozen=True)
class BoundingBox:
    """이미지 크기로 정규화된 좌상단 기준 bbox."""

    x: float
    y: float
    w: float
    h: float

    def __post_init__(self) -> None:
        values = (self.x, self.y, self.w, self.h)
        if not all(math.isfinite(value) for value in values):
            raise VisionResultValidationError("bbox values must be finite")
        if not (0.0 <= self.x < 1.0 and 0.0 <= self.y < 1.0):
            raise VisionResultValidationError("bbox x and y must be in [0, 1)")
        if not (0.0 < self.w <= 1.0 and 0.0 < self.h <= 1.0):
            raise VisionResultValidationError("bbox w and h must be in (0, 1]")
        if self.x + self.w > 1.0 or self.y + self.h > 1.0:
            raise VisionResultValidationError("bbox must not exceed image bounds")

    def as_dict(self) -> dict[str, float]:
        return {"x": self.x, "y": self.y, "w": self.w, "h": self.h}


@dataclass(frozen=True)
class RawDetection:
    """모델 어댑터가 제공하는 픽셀 단위 ``xyxy`` 결과."""

    class_id: str
    score: float
    x1: float
    y1: float
    x2: float
    y2: float


@dataclass(frozen=True)
class VisionDetection:
    """공유 계약에 전달 가능한 단일 객체 탐지 결과."""

    class_id: str
    score: float
    bbox: BoundingBox

    def as_dict(self) -> dict[str, object]:
        return {
            "classId": self.class_id,
            "bbox": self.bbox.as_dict(),
            "score": self.score,
        }


@dataclass(frozen=True)
class VisionResult:
    """한 프레임의 BBox/Class/Confidence 결과.

    방향·거리·위험 판단은 후속 단계의 별도 해석 계층에서 다룬다. 이 객체는
    모델이 관측한 사실만 담아 Context/Risk/Priority 계층과 분리한다.
    """

    frame_id: str
    captured_at: datetime
    image_size: ImageSize
    detections: tuple[VisionDetection, ...]
    model_name: str
    model_version: str

    def __post_init__(self) -> None:
        try:
            parsed_id = uuid.UUID(self.frame_id)
        except (TypeError, ValueError, AttributeError) as exc:
            raise VisionResultValidationError("frame_id must be a UUID") from exc
        if parsed_id.version != 4:
            raise VisionResultValidationError("frame_id must be a UUID v4")
        if self.captured_at.tzinfo is None or self.captured_at.utcoffset() is None:
            raise VisionResultValidationError("captured_at must include a timezone")
        if not self.model_name.strip() or not self.model_version.strip():
            raise VisionResultValidationError("model name and version are required")

    def as_contract_payload(self) -> dict[str, object]:
        """기존 pipeline README §3.1 후보 형식으로 직렬화한다.

        ``packages/shared_contracts``는 아직 팀 합의 전이므로 여기서는 해당 파일을
        수정하지 않고, 소비자가 검증할 수 있는 로컬 payload만 제공한다.
        """
        return {
            "frameId": self.frame_id,
            "capturedAt": self.captured_at.isoformat(),
            "imageSize": {"width": self.image_size.width, "height": self.image_size.height},
            "detections": [detection.as_dict() for detection in self.detections],
            "modelInfo": {"name": self.model_name, "version": self.model_version},
        }


def load_taxonomy_thresholds(path: Path = _TAXONOMY_PATH) -> dict[str, float]:
    """taxonomy에 정의된 학습 클래스와 모델 score 임계값을 불러온다."""
    try:
        taxonomy = json.loads(path.read_text(encoding="utf-8"))
        classes = taxonomy["classes"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        raise VisionResultValidationError(f"unable to load taxonomy: {path}") from exc

    thresholds: dict[str, float] = {}
    for item in classes:
        try:
            class_id = item["id"]
            threshold = float(item["detection_threshold"])
        except (KeyError, TypeError, ValueError) as exc:
            raise VisionResultValidationError("invalid taxonomy class threshold") from exc
        if not class_id or not 0.0 < threshold <= 1.0:
            raise VisionResultValidationError("taxonomy threshold must be in (0, 1]")
        thresholds[class_id] = threshold
    return thresholds


def _normalize_bbox(raw: RawDetection, image_size: ImageSize) -> BoundingBox:
    """pixel ``xyxy``를 이미지 경계 안의 정규화 bbox로 변환한다."""
    values = (raw.x1, raw.y1, raw.x2, raw.y2)
    if not all(math.isfinite(value) for value in values):
        raise VisionResultValidationError("raw bbox values must be finite")

    left = min(max(raw.x1, 0.0), float(image_size.width))
    top = min(max(raw.y1, 0.0), float(image_size.height))
    right = min(max(raw.x2, 0.0), float(image_size.width))
    bottom = min(max(raw.y2, 0.0), float(image_size.height))
    if right <= left or bottom <= top:
        raise VisionResultValidationError("raw bbox must have positive area inside the image")

    # float 반올림으로 정확히 1.0을 넘는 일을 막기 위해 최대값을 clamp한다.
    x = left / image_size.width
    y = top / image_size.height
    w = min((right - left) / image_size.width, 1.0 - x)
    h = min((bottom - top) / image_size.height, 1.0 - y)
    return BoundingBox(x=x, y=y, w=w, h=h)


def build_vision_result(
    *,
    frame_id: str,
    captured_at: datetime,
    image_size: ImageSize,
    raw_detections: Iterable[RawDetection],
    model_name: str,
    model_version: str,
    thresholds: dict[str, float] | None = None,
) -> VisionResult:
    """모델 출력을 검증·정규화·임계값 필터링해 ``VisionResult``로 만든다.

    taxonomy에 없는 클래스는 외부 계약으로 유출하지 않고 무시한다. 알려진 클래스의
    유효하지 않은 score 또는 bbox는 모델 어댑터 오류이므로 명시적으로 실패한다.
    """
    active_thresholds = thresholds if thresholds is not None else load_taxonomy_thresholds()
    detections: list[VisionDetection] = []

    for raw in raw_detections:
        if raw.class_id not in active_thresholds:
            continue
        if not math.isfinite(raw.score) or not 0.0 <= raw.score <= 1.0:
            raise VisionResultValidationError("raw detection score must be in [0, 1]")
        if raw.score < active_thresholds[raw.class_id]:
            continue
        detections.append(
            VisionDetection(
                class_id=raw.class_id,
                score=raw.score,
                bbox=_normalize_bbox(raw, image_size),
            )
        )

    return VisionResult(
        frame_id=frame_id,
        captured_at=captured_at,
        image_size=image_size,
        detections=tuple(detections),
        model_name=model_name,
        model_version=model_version,
    )
