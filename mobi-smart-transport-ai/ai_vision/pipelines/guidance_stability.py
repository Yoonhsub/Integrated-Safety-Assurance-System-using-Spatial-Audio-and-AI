"""실시간 카메라 안내 후보의 흔들림과 중복을 줄이는 상태 보관 필터.

이 모듈은 음성 문구나 위험도를 결정하지 않는다. 연속 프레임에서 같은 방향이
확인된 관측 후보만 Context/Audio 계층으로 넘겨, 한 프레임의 오탐·방향 흔들림과
반복 안내 가능성을 줄이는 AI Vision 참조 구현이다.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from datetime import datetime

from spatial_guidance import SpatialGuidance
from vision_result import VisionResultValidationError


@dataclass(frozen=True)
class GuidanceStabilityPolicy:
    """현장 검증 시작값. 실제 단말 시험으로 조정한다."""

    confirmation_frames: int = 3
    cooldown_seconds: float = 3.0
    max_candidates_per_frame: int = 1
    priority: tuple[str, ...] = ("bus_door", "bus", "bus_stop")

    def __post_init__(self) -> None:
        if self.confirmation_frames < 1:
            raise VisionResultValidationError("confirmation_frames must be positive")
        if self.cooldown_seconds < 0:
            raise VisionResultValidationError("cooldown_seconds must not be negative")
        if self.max_candidates_per_frame < 1:
            raise VisionResultValidationError("max_candidates_per_frame must be positive")
        if len(set(self.priority)) != len(self.priority):
            raise VisionResultValidationError("priority must not contain duplicates")


@dataclass
class GuidanceStabilizer:
    """프레임별 ``SpatialGuidance``를 안정된 안내 후보로 좁힌다.

    클래스마다 최근 후보를 보관한다. 같은 클래스가 연속 ``confirmation_frames``번
    같은 화면 방향으로 관측된 경우에만 후보가 된다. 같은 클래스·방향·거리 단계는
    cooldown 안에 다시 내보내지 않는다. 방향 또는 상대 거리 단계가 변하면, 다시
    연속 확인된 뒤 cooldown과 관계없이 새 후보로 내보낼 수 있다.
    """

    policy: GuidanceStabilityPolicy = field(default_factory=GuidanceStabilityPolicy)
    _history: dict[str, deque[SpatialGuidance]] = field(default_factory=dict, init=False, repr=False)
    _last_emitted: dict[str, tuple[tuple[str, str], datetime]] = field(default_factory=dict, init=False, repr=False)

    def filter(self, candidates: tuple[SpatialGuidance, ...], *, captured_at: datetime) -> tuple[SpatialGuidance, ...]:
        """안정화·중복 억제를 적용한 후보를 우선순위 순으로 반환한다."""
        if captured_at.tzinfo is None or captured_at.utcoffset() is None:
            raise VisionResultValidationError("captured_at must include a timezone")

        by_class = {candidate.class_id: candidate for candidate in candidates}
        for class_id in tuple(self._history):
            if class_id not in by_class:
                # 중간 프레임에서 사라진 대상은 새로 확인하도록 한다.
                self._history.pop(class_id)

        stable: list[SpatialGuidance] = []
        for class_id, candidate in by_class.items():
            history = self._history.setdefault(class_id, deque(maxlen=self.policy.confirmation_frames))
            history.append(candidate)
            if len(history) < self.policy.confirmation_frames:
                continue
            if any(item.direction != candidate.direction for item in history):
                continue

            signature = (candidate.direction.value, candidate.relative_distance.value)
            previous = self._last_emitted.get(class_id)
            if previous is not None and previous[0] == signature:
                elapsed = (captured_at - previous[1]).total_seconds()
                if elapsed < self.policy.cooldown_seconds:
                    continue
            stable.append(candidate)

        priority_index = {class_id: index for index, class_id in enumerate(self.policy.priority)}
        stable.sort(
            key=lambda candidate: (
                priority_index.get(candidate.class_id, len(priority_index)),
                -candidate.confidence,
                -candidate.normalized_area,
            )
        )
        selected = tuple(stable[: self.policy.max_candidates_per_frame])
        for candidate in selected:
            self._last_emitted[candidate.class_id] = (
                (candidate.direction.value, candidate.relative_distance.value),
                captured_at,
            )
        return selected
