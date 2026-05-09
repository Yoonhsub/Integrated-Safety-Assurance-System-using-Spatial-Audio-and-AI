"""공공데이터 원본 응답 필드 → 표준 모델 변환 헬퍼.

이 모듈은 ``services/public_data/README.md`` 섹션 2 "공공데이터 API 조사 결과"에서
1차 출처로 확정한 매핑 규칙을 함수로 표현한다. transport(``DataGoKrClient``)나
service(``BusArrivalsService``)가 아닌 **순수 매핑 계층**으로 분리되어 있어
단위 테스트가 쉽고, 다른 API(서울 BIS / TAGO / GBIS)별 구현이 공통 헬퍼를 재사용한다.

매핑 표 (서울 BIS ``getArrInfoByRouteAll`` 응답 필드 기준 — 1차 출처:
``http://api.bus.go.kr/contents/sub02/getArrInfoByRouteAll.html``):

| 원본 필드      | 원본 값                                | 표준 필드/값                         |
|---------------|---------------------------------------|------------------------------------|
| ``busType*``  | ``0`` 일반 / ``1`` 저상 / ``2`` 굴절 | ``lowFloor``: 저상만 ``True``       |
| ``reride_Num*`` | ``0`` 데이터없음 / ``3`` 여유 / ``4`` 보통 / ``5`` 혼잡 | ``congestion``: ``UNKNOWN/LOW/NORMAL/HIGH`` |
| ``exps*``     | 도착 예정 초 (정수, ≥0)              | ``arrivalMinutes``: ``round(seconds / 60)`` |

원칙:
- 원본 값을 ``str(...)``로 변환한 뒤 비교한다 (서울 BIS 응답은 XML 텍스트라 모두 문자열).
- 매핑 표에 없는 값(빈 문자열, ``None``, 미상 코드 등)은 모두 안전한 기본값으로 흡수:
  ``lowFloor`` → ``False`` 또는 ``None`` (호출자 선택), ``congestion`` → ``UNKNOWN``.
- 음수 초나 이상치는 ``ValueError`` 대신 ``0``으로 정규화하지 않고 호출자가 결정.
  여기서는 ``arrivalMinutes < 0`` 방지를 위해 ``max(0, ...)``를 적용한다.

TODO(김도성, 섹션 8 또는 10):
- TAGO ``ArvlInfoInqireService``의 ``vehicletp`` / 혼잡도 필드명·코드를 활용신청
  명세서로 확인하여 ``map_vehicle_type_to_low_floor`` 인자에 다른 코드 set을 추가한다.
"""

from __future__ import annotations

from .schemas import CongestionLevel

# 서울 BIS busType 코드 매핑 (출처: 본 모듈 docstring 참조 URL)
_SEOUL_BUS_TYPE_CODE_LOW_FLOOR = "1"  # 저상버스
# "0"=일반, "2"=굴절은 lowFloor=False로 매핑.
# 그 외(빈 값, None, 알 수 없는 코드)는 기본값 None을 반환하여 호출자가
# 정책(False로 단정 vs 미상 표기)을 결정하도록 한다 — README §4와 일관.

# 서울 BIS reride_Num 코드 매핑
_SEOUL_RERIDE_TO_CONGESTION = {
    "0": CongestionLevel.UNKNOWN,  # 데이터없음
    "3": CongestionLevel.LOW,       # 여유
    "4": CongestionLevel.NORMAL,    # 보통
    "5": CongestionLevel.HIGH,      # 혼잡
}


def map_vehicle_type_to_low_floor(
    raw_value,
    *,
    default: bool | None = None,
) -> bool | None:
    """원본 차량유형 코드 → ``lowFloor: bool | None``.

    서울 BIS ``busType*`` (0=일반, 1=저상, 2=굴절) 매핑.
    저상버스는 ``True``, 일반/굴절은 ``False``.
    빈 값/None/알 수 없는 코드는 ``default`` (기본 ``None``).

    호출자(섹션 6 빈 응답 정책 참고)는:
    - "저상 정보가 확실하지 않으면 카드를 안 띄우거나 'lowFloor 미상' 표기" 정책이면 ``default=None``
    - "확실하지 않으면 일반 차량으로 간주" 정책이면 ``default=False``

    원본 응답에 ``busType``이 아예 누락된 경우(원본 API 자체가 vehicletp를 제공 안 함)
    호출자는 본 함수를 호출하지 말고 lowFloor 필드를 미상으로 두는 결정을 별도로 내린다.
    """
    if raw_value is None:
        return default
    s = str(raw_value).strip()
    if not s:
        return default
    if s == _SEOUL_BUS_TYPE_CODE_LOW_FLOOR:
        return True
    if s in {"0", "2"}:  # 일반, 굴절 → False
        return False
    return default  # 알 수 없는 코드


def map_reride_to_congestion(raw_value) -> CongestionLevel:
    """원본 재차 인원 코드 → ``CongestionLevel``.

    서울 BIS ``reride_Num*`` (0/3/4/5) 매핑.
    매핑 표 외 값(빈 값, None, 알 수 없는 코드)은 모두 ``UNKNOWN``.

    호출자는 결과를 그대로 ``NormalizedBusArrival.congestion``에 넣는다 —
    표준 응답에서 congestion은 항상 enum 값이며 누락되지 않는다 (README §5).
    """
    if raw_value is None:
        return CongestionLevel.UNKNOWN
    s = str(raw_value).strip()
    return _SEOUL_RERIDE_TO_CONGESTION.get(s, CongestionLevel.UNKNOWN)


def seconds_to_arrival_minutes(raw_seconds) -> int:
    """원본 도착 예정 초 → 분 단위 정수.

    서울 BIS ``exps*``는 정수 초 값(예: ``60``=1분 후, ``180``=3분 후).
    분 환산은 Python 내장 ``round(seconds / 60)``로 수행한다.

    중요 — Python ``round()``는 **banker's rounding** (round half to even)을
    사용하므로 ``.5`` 경계값에서 짝수 쪽으로 떨어진다. 다음 예시를 참고:

    ====================  =======================  ==========
    원본 초                 ``seconds / 60``           반환값
    ====================  =======================  ==========
    ``20``                ``0.333``                 ``0``
    ``29``                ``0.483``                 ``0``
    ``30``                ``0.5``  (banker → 0)     ``0``
    ``31``                ``0.516``                 ``1``
    ``60``                ``1.0``                   ``1``
    ``89``                ``1.483``                 ``1``
    ``90``                ``1.5``  (banker → 2)     ``2``
    ``91``                ``1.516``                 ``2``
    ``180``               ``3.0``                   ``3``
    ====================  =======================  ==========

    즉 ``30초``는 ``0분``, ``90초``는 ``2분``으로 매핑된다 — 일반적인
    "0.5는 위로 올림" 인식과 다를 수 있어 사용자 인터페이스에서 "곧 도착" 라벨을
    표시할 임계값을 별도로 두고 싶다면 호출자가 본 함수 대신 자체 변환을 사용한다.
    본 함수는 단순 ``round`` 동작을 그대로 노출한다.

    음수/잘못된 값은 ``0``으로 정규화한다 (``arrivalMinutes`` Pydantic 제약 ``ge=0``).

    Raises:
        TypeError: ``raw_seconds``가 숫자/숫자 문자열이 아니면.
    """
    if raw_seconds is None:
        raise TypeError("raw_seconds must not be None")
    try:
        if isinstance(raw_seconds, str):
            seconds = float(raw_seconds.strip())
        else:
            seconds = float(raw_seconds)
    except (ValueError, TypeError) as exc:
        raise TypeError(f"raw_seconds must be numeric, got {raw_seconds!r}") from exc

    if seconds < 0:
        return 0
    return int(round(seconds / 60))
