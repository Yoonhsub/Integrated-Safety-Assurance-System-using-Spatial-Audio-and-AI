"""저상버스 우선 정렬 및 필터링.

표준 모델 ``NormalizedBusArrival.lowFloor: bool``은 항상 결정된 값이다
(``True`` 또는 ``False`` — shared schema가 필수 boolean으로 강제).
"저상 정보가 미상"인 케이스는 normalize 단계에서 안전 기본값(``False``)으로
이미 흡수되므로, 본 모듈은 미상 처리를 별도로 하지 않는다.

함수 두 종류를 제공한다:

- ``prioritize_low_floor``  : 저상버스를 앞으로 정렬하되, 일반버스도 결과에 남긴다.
                              교통약자가 저상 우선으로 보되 일반 버스도 옵션으로 보고 싶을 때.
- ``filter_low_floor_only`` : 저상버스만 남기고 일반버스는 제외한다.
                              교통약자가 저상 외에는 어차피 못 타는 케이스에 사용.

두 함수 모두 부작용 없이 새 list를 반환하며, 입력 list는 변경하지 않는다.
"""

from __future__ import annotations

from .schemas import NormalizedBusArrival


def prioritize_low_floor(
    arrivals: list[NormalizedBusArrival],
) -> list[NormalizedBusArrival]:
    """저상버스를 우선 표시하도록 정렬한다.

    정렬 키:
    1. 저상버스가 먼저 (``lowFloor=True`` 우선).
    2. 같은 저상 여부 안에서는 ``arrivalMinutes`` 오름차순 (먼저 도착하는 버스 우선).

    원본 list는 변경하지 않는다.
    """
    return sorted(arrivals, key=lambda item: (not item.lowFloor, item.arrivalMinutes))


def filter_low_floor_only(
    arrivals: list[NormalizedBusArrival],
) -> list[NormalizedBusArrival]:
    """저상버스만 남긴다.

    ``arrivalMinutes`` 오름차순으로 정렬한 결과를 반환한다.
    저상버스가 한 대도 없으면 빈 list를 반환한다 — 호출자(UI)는 이 빈 list를
    "현재 저상버스 도착 정보 없음"으로 해석할 수 있다.
    """
    low = [a for a in arrivals if a.lowFloor]
    return sorted(low, key=lambda item: item.arrivalMinutes)

