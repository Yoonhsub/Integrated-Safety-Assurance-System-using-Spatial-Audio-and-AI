"""저상버스 / 접근성 필터링 및 정렬 헬퍼.

V1(4월) 단계에서 `prioritize_low_floor`, `filter_low_floor_only` 두 함수를 만들었고,
V2 단계에서 호출자(심현석 backend gateway, 윤현섭 Flutter UI 등)가 접근성 옵션을
명확하게 토글할 수 있도록 다음을 추가한다:

- **`AccessibilityMode` enum (4종)** — UI 토글 또는 백엔드 query parameter로 사용할 옵션.
- **`is_accessible(arrival)`** — 접근성 신호 통합 헬퍼. 현재는 ``lowFloor``만 보지만
  향후 다른 신호(휠체어 리프트 코드 등)가 normalize 단계에서 추가되어도 본 헬퍼만
  수정하면 다른 함수는 그대로 동작.
- **`filter_accessible_arrivals`** — accessible-only filter (V1 ``filter_low_floor_only``의
  V2 용어 별칭이자 통합 진입점).
- **`sort_by_accessibility`** — accessibility 정렬 (V1 ``prioritize_low_floor`` 강화판,
  ``include_congestion=True``로 혼잡도까지 보조 키 정렬 가능).
- **`apply_accessibility_filter(arrivals, mode=...)`** — 1줄 dispatch 헬퍼.
  UI 토글이나 API query param이 ``AccessibilityMode``로 들어왔을 때 한 줄로 처리.

V1 함수 ``prioritize_low_floor`` / ``filter_low_floor_only``는 그대로 보존하여 기존
import가 깨지지 않게 한다. 새 코드는 V2 신규 함수를 사용하는 것을 권장.

설계 원칙:

- 모든 함수는 **부작용 0** — 새 list를 반환하며 입력 list는 변경하지 않는다.
- 빈 list 입력에는 빈 list 반환 (V2 섹션 3 ``_normalize_arrivals`` 정밀화와 일관).
- 표준 모델 ``NormalizedBusArrival.lowFloor: bool``은 항상 결정된 값이다 (shared schema가
  필수 boolean으로 강제). "저상 정보 미상"은 normalize 단계에서 ``False``로 흡수됨.
"""

from __future__ import annotations

from enum import Enum

from .schemas import CongestionLevel, NormalizedBusArrival


# ---------------------------------------------------------------------------
# V2 신규: AccessibilityMode + is_accessible + 통합 헬퍼
# ---------------------------------------------------------------------------


class AccessibilityMode(str, Enum):
    """접근성 필터 모드 — 호출자가 선택하는 4가지 옵션.

    ``str`` 자식 enum으로 정의하여 ``"off"`` 같은 raw 문자열도 그대로 비교 가능
    (UI 토글 또는 API query parameter에서 들어온 값 호환).

    - ``OFF``        : 필터링·정렬 없음. 원본 순서 그대로 반환 (단, 새 list 사본).
    - ``PRIORITIZE`` : 저상 우선 정렬. 일반버스도 결과에 남는다. ``arrivalMinutes``를
                       보조 키로 사용.
    - ``ONLY``       : 저상버스만 남긴다. 일반버스 제외. ``arrivalMinutes`` 오름차순.
    - ``STRICT``     : 저상 + 혼잡도 ``LOW`` 또는 ``NORMAL``만 남긴다. ``HIGH``·
                       ``UNKNOWN``은 제외. 휠체어/유모차 사용자가 안전하게 탈 수 있는
                       조건으로 가장 엄격하게 필터.
    """

    OFF = "off"
    PRIORITIZE = "prioritize"
    ONLY = "only"
    STRICT = "strict"


def is_accessible(arrival: NormalizedBusArrival) -> bool:
    """주어진 도착 정보가 교통약자 접근 가능 차량인지 판정한다.

    현재(V2 시점)는 ``lowFloor`` 단일 신호만 사용한다. 향후 normalize 단계에서
    휠체어 리프트 코드, 저상 + 자동 경사판 옵션 등이 추가되면 본 헬퍼 한 곳만
    수정하면 다른 모든 함수가 같이 갱신된다.
    """
    return bool(arrival.lowFloor)


def _is_low_congestion(arrival: NormalizedBusArrival) -> bool:
    """STRICT 모드용 보조 판정 — 혼잡도가 LOW 또는 NORMAL이면 True.

    ``HIGH``는 휠체어/유모차 진입이 사실상 불가능한 상태로 본다.
    ``UNKNOWN``은 정보 부족이라 STRICT 모드에서는 보수적으로 제외한다.
    """
    return arrival.congestion in (CongestionLevel.LOW, CongestionLevel.NORMAL)


def filter_accessible_arrivals(
    arrivals: list[NormalizedBusArrival],
) -> list[NormalizedBusArrival]:
    """접근 가능한 차량만 남긴다 (accessible-only filter).

    V1 ``filter_low_floor_only``의 V2 용어 별칭. 현재 동작은 동일하지만 향후
    ``is_accessible`` 헬퍼가 다른 신호(휠체어 리프트 등)도 포함하도록 확장될 때
    본 함수는 자동으로 새 신호를 반영한다.

    정렬: ``arrivalMinutes`` 오름차순 (먼저 도착하는 버스 우선).
    빈 list 입력 또는 접근 가능 차량이 없는 경우 빈 list 반환.
    """
    if not arrivals:
        return []
    accessible = [a for a in arrivals if is_accessible(a)]
    return sorted(accessible, key=lambda item: item.arrivalMinutes)


def sort_by_accessibility(
    arrivals: list[NormalizedBusArrival],
    *,
    include_congestion: bool = False,
) -> list[NormalizedBusArrival]:
    """접근성 기준으로 정렬한다 (accessibility sort).

    V1 ``prioritize_low_floor``의 V2 강화판. 일반버스도 결과에 남기고 저상버스만
    앞으로 가져온다.

    정렬 키:

    1. ``is_accessible(arrival)`` 가 True인 것이 먼저.
    2. 만약 ``include_congestion=True``이면, 같은 접근 그룹 안에서 혼잡도가
       낮은 것이 우선 (LOW < NORMAL < HIGH < UNKNOWN 순). 휠체어/유모차 사용자가
       타기 좋은 조건을 우선 보여주고 싶을 때 사용.
    3. 마지막으로 ``arrivalMinutes`` 오름차순.

    원본 list는 변경하지 않는다.
    """
    if not arrivals:
        return []

    # 혼잡도 정렬 우선순위 — LOW=0, NORMAL=1, HIGH=2, UNKNOWN=3 (낮을수록 우선)
    congestion_rank = {
        CongestionLevel.LOW: 0,
        CongestionLevel.NORMAL: 1,
        CongestionLevel.HIGH: 2,
        CongestionLevel.UNKNOWN: 3,
    }

    def sort_key(item: NormalizedBusArrival) -> tuple:
        accessible_first = 0 if is_accessible(item) else 1
        if include_congestion:
            congestion_key = congestion_rank.get(item.congestion, 3)
            return (accessible_first, congestion_key, item.arrivalMinutes)
        return (accessible_first, item.arrivalMinutes)

    return sorted(arrivals, key=sort_key)


def apply_accessibility_filter(
    arrivals: list[NormalizedBusArrival],
    mode: AccessibilityMode | str = AccessibilityMode.OFF,
) -> list[NormalizedBusArrival]:
    """``AccessibilityMode``에 따라 한 줄로 필터/정렬을 dispatch한다.

    UI 토글 또는 API query parameter가 ``AccessibilityMode`` 또는 raw 문자열로
    들어왔을 때 한 줄로 처리하기 위한 진입점. ``mode``가 ``str``이면 ``AccessibilityMode``
    enum으로 변환한 후 dispatch한다. 알 수 없는 값은 ``OFF``로 보수적 fallback.

    - ``OFF``         → 원본 순서 그대로 (새 list 사본)
    - ``PRIORITIZE``  → ``sort_by_accessibility(arrivals)`` (혼잡도 미고려)
    - ``ONLY``        → ``filter_accessible_arrivals(arrivals)``
    - ``STRICT``      → 저상 + 혼잡도 LOW/NORMAL만, ``arrivalMinutes`` 오름차순.

    원본 list는 변경하지 않는다. 빈 입력은 빈 list 반환.
    """
    if not arrivals:
        return []

    if isinstance(mode, str) and not isinstance(mode, AccessibilityMode):
        try:
            mode = AccessibilityMode(mode.lower())
        except ValueError:
            mode = AccessibilityMode.OFF  # 보수적 fallback

    if mode == AccessibilityMode.OFF:
        return list(arrivals)  # 사본 반환 (부작용 0 보장)
    if mode == AccessibilityMode.PRIORITIZE:
        return sort_by_accessibility(arrivals)
    if mode == AccessibilityMode.ONLY:
        return filter_accessible_arrivals(arrivals)
    if mode == AccessibilityMode.STRICT:
        strict = [a for a in arrivals if is_accessible(a) and _is_low_congestion(a)]
        return sorted(strict, key=lambda item: item.arrivalMinutes)

    # 정의되지 않은 모드 — 도달 불가능하지만 안전 처리
    return list(arrivals)


# ---------------------------------------------------------------------------
# V1 하위 호환 함수 (그대로 보존)
# ---------------------------------------------------------------------------


def prioritize_low_floor(
    arrivals: list[NormalizedBusArrival],
) -> list[NormalizedBusArrival]:
    """저상버스를 우선 표시하도록 정렬한다 (V1 함수, V2에서 유지).

    V2 신규 코드는 ``sort_by_accessibility`` 사용을 권장.

    정렬 키:
    1. 저상버스가 먼저 (``lowFloor=True`` 우선).
    2. 같은 저상 여부 안에서는 ``arrivalMinutes`` 오름차순 (먼저 도착하는 버스 우선).

    원본 list는 변경하지 않는다.
    """
    return sorted(arrivals, key=lambda item: (not item.lowFloor, item.arrivalMinutes))


def filter_low_floor_only(
    arrivals: list[NormalizedBusArrival],
) -> list[NormalizedBusArrival]:
    """저상버스만 남긴다 (V1 함수, V2에서 유지).

    V2 신규 코드는 ``filter_accessible_arrivals`` 사용을 권장.

    ``arrivalMinutes`` 오름차순으로 정렬한 결과를 반환한다.
    저상버스가 한 대도 없으면 빈 list를 반환한다 — 호출자(UI)는 이 빈 list를
    "현재 저상버스 도착 정보 없음"으로 해석할 수 있다.
    """
    low = [a for a in arrivals if a.lowFloor]
    return sorted(low, key=lambda item: item.arrivalMinutes)
