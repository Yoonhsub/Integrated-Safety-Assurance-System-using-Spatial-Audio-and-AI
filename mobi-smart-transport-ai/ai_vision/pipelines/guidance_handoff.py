"""AI Vision에서 Context/음성 담당자에게 전달할 안내 후보 payload.

이 파일의 형식은 ``ai_vision`` 내부의 *합의용 후보*다. 공통 계약 폴더를
수정하지 않으며, Context/SAL/음성 정책이나 사용자 문구를 결정하지 않는다.
"""

from __future__ import annotations

from dataclasses import dataclass

from spatial_guidance import SpatialGuidance, interpret_bus_door_guidance, interpret_bus_guidance
from vision_result import VisionResult


PROPOSED_SCHEMA_VERSION = "0.1.0-proposed"


@dataclass(frozen=True)
class VisionGuidanceHandoff:
    """한 프레임에서 AI Vision이 관측·해석한 안내 후보 묶음.

    ``candidates``는 빈 목록일 수 있다. 이는 버스가 없다고 단정하는 값이 아니라,
    해당 프레임에서 신뢰 가능한 안내 후보가 없다는 뜻이다.
    """

    frame_id: str
    captured_at: str
    candidates: tuple[SpatialGuidance, ...]
    schema_version: str = PROPOSED_SCHEMA_VERSION

    def as_dict(self) -> dict[str, object]:
        return {
            "schemaVersion": self.schema_version,
            "frameId": self.frame_id,
            "capturedAt": self.captured_at,
            "candidates": [
                {
                    "classId": candidate.class_id,
                    "direction": candidate.direction.value,
                    "relativeDistance": candidate.relative_distance.value,
                    "motion": candidate.motion.value,
                    "confidence": candidate.confidence,
                    "normalizedArea": candidate.normalized_area,
                }
                for candidate in self.candidates
            ],
        }


def build_vision_guidance_handoff(
    current: VisionResult,
    previous: VisionResult | None = None,
) -> VisionGuidanceHandoff:
    """VisionResult를 Context/음성 소비용 안내 후보 payload로 변환한다.

    위험도, 음성 문장, 음성 출력 우선순위는 이 함수가 정하지 않는다. 그 판단은
    Context/SAL/음성 담당 모듈의 책임이며, 여기서는 검증 가능한 관측·해석 값만
    전달한다.
    """
    bus_guidance = interpret_bus_guidance(current, previous)
    door_guidance = interpret_bus_door_guidance(current, previous)
    return VisionGuidanceHandoff(
        frame_id=current.frame_id,
        captured_at=current.captured_at.isoformat(),
        candidates=tuple(candidate for candidate in (bus_guidance, door_guidance) if candidate is not None),
    )
