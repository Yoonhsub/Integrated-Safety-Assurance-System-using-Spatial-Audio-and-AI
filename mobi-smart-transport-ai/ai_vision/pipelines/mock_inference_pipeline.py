"""Mock AI Inference Pipeline — V2 섹션 8 산출물.

본 모듈은 김도성 V2 에이전트가 V2 섹션 8 (Mock AI Inference Pipeline)에서 작성한
**stub-only** 추론 파이프라인이다. **실제 모델 호출은 일절 하지 않으며**, ``fixtures/
mock_safety_events.json``을 로드해 Safety Event 후보 schema(§3.4)와 정합한 dict를
반환한다.

본 모듈의 목적은 다음 세 가지를 후속 통합 단계의 출발점으로 제공하는 것이다:

1. **윤현섭 Flutter UI** 가 mock Safety Event를 받아 음성·진동·시각 UI로 변환하는
   통합 흐름을 2학기 단계 3 전에도 시뮬레이션 가능.
2. **심현석 backend** 가 mock Safety Event를 받아 FCM 알림·rideRequests 위험 기록
   같은 2차 동작을 통합 테스트 가능.
3. **김도성 V2 섹션 10** (mock pipeline 검증) 의 입력 — 본 모듈의 출력이 §3.4 schema
   계약을 충족하는지 시나리오 단위로 검증.

설계 원칙:

- 외부 모델/네트워크 호출 0건. stdlib만 사용.
- 본 모듈을 import해도 부작용 0 (fixture 파일은 함수 호출 시점에만 로드).
- fixture 파일이 손상되면 ``MockInferenceError``를 raise (silent fallback 금지).
- 실제 추론 코드는 2학기 단계 1·2에서 별도 작성 — 본 모듈은 그때 교체될 수도, mock 모드용
  으로 남을 수도 있다 (V2 섹션 5의 BusArrivalsService mock/live 분리 패턴과 같은 의도).

실행 환경 제약:

- Pydantic 인스턴스 검증은 본 모듈 범위 밖이다. fixture가 §3.4 schema와 정합한지는
  V2 섹션 10 검증에서 stdlib JSON Schema 비교 또는 운영 환경 Pydantic으로 별도 수행.
- 호출자는 본 모듈 출력을 dict로 받아 자유롭게 가공하거나 Pydantic 모델로 검증 가능.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


# 본 fixture 파일은 본 모듈과 같은 디렉토리의 fixtures/ 안에 있다.
DEFAULT_FIXTURE_PATH = (
    Path(__file__).resolve().parent / "fixtures" / "mock_safety_events.json"
)


class MockInferenceError(Exception):
    """Mock pipeline 실패 — fixture 파일 손상 / 누락 / 형식 오류."""


def _load_fixture(path: Path | None = None) -> dict[str, Any]:
    """fixture JSON을 dict로 로드한다.

    파일이 없거나 JSON 손상 시 ``MockInferenceError``를 raise. 호출자가 catch해서
    silent fallback 하지 않도록 명시적으로 실패한다 (BusArrivalsService의
    ``LiveBusArrivalsProvider`` 가드 패턴과 동일 의도).
    """
    fixture_path = path or DEFAULT_FIXTURE_PATH
    if not fixture_path.exists():
        raise MockInferenceError(
            f"Mock fixture not found: {fixture_path}. "
            "Check ai_vision/pipelines/fixtures/mock_safety_events.json."
        )
    try:
        with fixture_path.open(encoding="utf-8") as f:
            payload = json.load(f)
    except json.JSONDecodeError as exc:
        raise MockInferenceError(
            f"Mock fixture is corrupted JSON: {fixture_path}. {exc}"
        ) from exc

    if not isinstance(payload, dict) or "events" not in payload:
        raise MockInferenceError(
            f"Mock fixture missing 'events' key: {fixture_path}"
        )
    if not isinstance(payload["events"], list):
        raise MockInferenceError(
            f"Mock fixture 'events' is not a list: {fixture_path}"
        )
    return payload


def get_all_events(*, path: Path | None = None) -> list[dict[str, Any]]:
    """모든 Safety Event mock 4건을 list로 반환한다.

    원본 list의 사본을 반환하므로 호출자가 변경해도 다음 호출에 영향 없음.
    """
    payload = _load_fixture(path)
    return [dict(event) for event in payload["events"]]


def get_events_by_risk(
    risk_level: str,
    *,
    path: Path | None = None,
) -> list[dict[str, Any]]:
    """주어진 ``risk_level`` (info / warn / danger) 의 Safety Event만 필터링.

    enum 외 값을 넘기면 빈 list 반환 (호출자 책임).
    """
    return [
        e for e in get_all_events(path=path)
        if e.get("riskLevel") == risk_level
    ]


def get_event_by_id(
    event_id: str,
    *,
    path: Path | None = None,
) -> dict[str, Any] | None:
    """주어진 ``eventId`` 의 Safety Event 1건을 반환. 없으면 ``None``.

    backend 측에서 멱등성 검증(같은 eventId 중복 수신 시 무시)을 통합 테스트할 때 사용.
    """
    for event in get_all_events(path=path):
        if event.get("eventId") == event_id:
            return event
    return None


def get_fixture_schema_reference(*, path: Path | None = None) -> str:
    """fixture 파일이 어느 schema 후보를 따르는지 명시 문자열 반환.

    호출자가 fixture 형식의 출처를 자동으로 추적하기 위함 (예: V2 섹션 10 검증
    시점에 정합성 비교 대상 schema 위치 자동 식별).
    """
    payload = _load_fixture(path)
    return str(payload.get("schema_reference", ""))


# ---------------------------------------------------------------------------
# CLI 진입점 (수동 검사용 — pytest나 unittest와 무관)
# ---------------------------------------------------------------------------


def _print_summary() -> None:
    """``python -m ai_vision.pipelines.mock_inference_pipeline`` 으로 호출 시 요약 출력."""
    events = get_all_events()
    print(f"Mock Safety Event fixture: {len(events)}건 로드")
    print(f"Schema reference: {get_fixture_schema_reference()}")
    print()
    print(f"{'eventId':40} {'riskLevel':10} {'reason':25} primaryClass")
    print("-" * 95)
    for event in events:
        print(
            f"{event['eventId']:40} "
            f"{event['riskLevel']:10} "
            f"{event['reason']:25} "
            f"{event['primaryClass']}"
        )


if __name__ == "__main__":
    _print_summary()
