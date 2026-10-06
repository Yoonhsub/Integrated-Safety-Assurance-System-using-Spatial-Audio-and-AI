"""버스 탐지 결과를 화면 기준의 안내 정보로 해석한다.

이 모듈은 실제 거리 측정기가 아니다. 단일 카메라 프레임에서 버스 bbox가
차지하는 비율을 사용해 ``FAR/MEDIUM/NEAR``라는 *상대적 화면 거리 단계*를
만들고, 연속 프레임의 비율 변화를 사용해 접근 여부를 추정한다. 실제 미터
거리나 충돌 위험도는 이후 Context/SAL 계층에서 별도 센서와 함께 판단해야 한다.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from vision_result import VisionDetection, VisionResult


class ScreenDirection(StrEnum):
    """프레임을 3등분한 화면상 수평 위치."""

    LEFT = "LEFT"
    CENTER = "CENTER"
    RIGHT = "RIGHT"


class RelativeDistance(StrEnum):
    """bbox 면적에 따른 화면 기준 거리 단계. 실제 거리 단위가 아니다."""

    FAR = "FAR"
    MEDIUM = "MEDIUM"
    NEAR = "NEAR"


class MotionState(StrEnum):
    """같은 대상 클래스의 bbox 면적 변화로 만든 상태."""

    UNKNOWN = "UNKNOWN"
    APPROACHING = "APPROACHING"
    STABLE = "STABLE"
    RECEDING = "RECEDING"


# 화면 전체 면적 대비 bbox 면적 기준이다. 카메라 화각과 실제 사용자 시험으로
# 보정할 임시값이며, 이 값만 바꾸면 거리 단계 정책을 교체할 수 있다.
MEDIUM_AREA_THRESHOLD = 0.05
NEAR_AREA_THRESHOLD = 0.20

# 이전 프레임보다 25% 이상 커지거나 20% 이상 작아질 때만 움직임으로 안내한다.
# 작은 detector 흔들림으로 접근/이탈 안내가 반복되는 일을 줄이기 위한 여유값이다.
APPROACHING_AREA_RATIO = 1.25
RECEDING_AREA_RATIO = 0.80


@dataclass(frozen=True)
class SpatialGuidance:
    """한 프레임의 버스 대상 안내 후보.

    ``relative_distance``는 화면상 크기 단계이고, ``motion``은 이전 프레임과
    비교할 수 있을 때만 확정한다. 음성 모듈은 이 객체를 받아 문장화할 수 있다.
    """

    frame_id: str
    class_id: str
    direction: ScreenDirection
    relative_distance: RelativeDistance
    motion: MotionState
    confidence: float
    normalized_area: float

    def as_dict(self) -> dict[str, object]:
        return {
            "frameId": self.frame_id,
            "classId": self.class_id,
            "direction": self.direction.value,
            "relativeDistance": self.relative_distance.value,
            "motion": self.motion.value,
            "confidence": self.confidence,
            "normalizedArea": self.normalized_area,
        }


def _area(detection: VisionDetection) -> float:
    return detection.bbox.w * detection.bbox.h


def _largest_detection(result: VisionResult, class_id: str) -> VisionDetection | None:
    """동일 클래스가 여럿이면 화면에서 가장 큰 대상을 안내 대상으로 선택한다."""
    candidates = (detection for detection in result.detections if detection.class_id == class_id)
    return max(candidates, key=_area, default=None)


def _direction(detection: VisionDetection) -> ScreenDirection:
    center_x = detection.bbox.x + detection.bbox.w / 2
    if center_x < 1 / 3:
        return ScreenDirection.LEFT
    if center_x > 2 / 3:
        return ScreenDirection.RIGHT
    return ScreenDirection.CENTER


def _relative_distance(area: float) -> RelativeDistance:
    if area >= NEAR_AREA_THRESHOLD:
        return RelativeDistance.NEAR
    if area >= MEDIUM_AREA_THRESHOLD:
        return RelativeDistance.MEDIUM
    return RelativeDistance.FAR


def _motion(current_area: float, previous_area: float | None) -> MotionState:
    if previous_area is None or previous_area <= 0:
        return MotionState.UNKNOWN
    if current_area >= previous_area * APPROACHING_AREA_RATIO:
        return MotionState.APPROACHING
    if current_area <= previous_area * RECEDING_AREA_RATIO:
        return MotionState.RECEDING
    return MotionState.STABLE


def interpret_bus_guidance(
    current: VisionResult,
    previous: VisionResult | None = None,
) -> SpatialGuidance | None:
    """현재·이전 ``VisionResult``에서 가장 큰 버스의 안내 후보를 만든다.

    현재 프레임에 지원된 ``bus`` 탐지가 없으면 ``None``을 반환한다. 이는
    "버스가 없음"을 단정하는 신호가 아니라, 이번 프레임에는 안내할 만큼
    신뢰 가능한 버스 탐지 결과가 없다는 뜻이다.
    """
    current_bus = _largest_detection(current, "bus")
    if current_bus is None:
        return None

    previous_bus = _largest_detection(previous, "bus") if previous is not None else None
    current_area = _area(current_bus)
    previous_area = _area(previous_bus) if previous_bus is not None else None
    return SpatialGuidance(
        frame_id=current.frame_id,
        class_id=current_bus.class_id,
        direction=_direction(current_bus),
        relative_distance=_relative_distance(current_area),
        motion=_motion(current_area, previous_area),
        confidence=current_bus.score,
        normalized_area=current_area,
    )
