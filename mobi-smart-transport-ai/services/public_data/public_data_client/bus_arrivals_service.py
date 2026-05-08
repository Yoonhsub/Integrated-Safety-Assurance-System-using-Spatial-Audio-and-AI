"""정류장별 도착 정보 표준화 서비스 skeleton.

이 모듈은 외부 호출자(현재는 동일 services/public_data 내부 사용 예시,
향후 심현석 백엔드)가 사용할 단일 진입점이다.
호출자는 ``BusArrivalsService().get_arrivals(stop_id)``를 호출하면
``NormalizedBusArrivalsResponse``(=``BusArrivalsResponse`` 공식 계약)를 돌려받는다.

mock/real 경계는 ``PUBLIC_DATA_USE_MOCK`` 환경변수가 결정한다.
- ``PUBLIC_DATA_USE_MOCK=true``  (또는 미설정): mock 응답 사용. 4월 MVP 기본.
- ``PUBLIC_DATA_USE_MOCK=false``               : real provider 사용 (섹션 6에서 본격 구현).

설계 책임 분리:
- ``DataGoKrClient``       : transport-only. HTTP 호출과 예외 변환.
- ``MockBusArrivalsProvider`` : mock JSON 파일을 읽어 표준 모델로 변환.
- ``LiveBusArrivalsProvider`` : 실제 API 호출 + 원본 응답 normalize (섹션 6).
- ``BusArrivalsService``    : 환경변수 기반 disp + 호출자 진입점.

TODO(김도성, 섹션 6):
- ``LiveBusArrivalsProvider._call_arrivals_api`` 실제 endpoint 호출 구현.
- 원본 응답 → ``NormalizedBusArrival`` 변환 (busType→lowFloor, reride_Num→congestion).
- 빈 응답을 빈 ``arrivals`` 정상 응답으로 만들지 예외로 처리할지 정책 확정.
- 저상버스 우선 정렬/필터를 호출 결과에 자동 적용할지 결정.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from .data_go_kr_client import DataGoKrClient
from .exceptions import (
    PublicDataEmptyResponseError,
    PublicDataNetworkError,
)
from .schemas import (
    CongestionLevel,
    NormalizedBusArrival,
    NormalizedBusArrivalsResponse,
)

# services/public_data/examples/mock_bus_arrivals.json 위치
# this file: services/public_data/public_data_client/bus_arrivals_service.py
DEFAULT_MOCK_PATH = (
    Path(__file__).resolve().parent.parent / "examples" / "mock_bus_arrivals.json"
)


def _is_mock_mode() -> bool:
    """``PUBLIC_DATA_USE_MOCK`` 평가.

    - 미설정         → True  (4월 MVP 기본 mock-first 정책)
    - ``true/1/yes`` → True
    - ``false/0/no`` → False
    - 그 외 값        → True  (보수적으로 mock 유지. 운영에서는 명시값을 권장.)
    """
    raw = os.getenv("PUBLIC_DATA_USE_MOCK")
    if raw is None:
        return True
    return raw.strip().lower() not in {"false", "0", "no", "off"}


class MockBusArrivalsProvider:
    """mock JSON 파일에서 표준 응답을 만들어 돌려주는 provider.

    - 4월 MVP 기본 경로.
    - mock JSON은 ``services/public_data/examples/mock_bus_arrivals.json``이며
      shared schema(``packages/shared_contracts/api/bus_arrivals.response.schema.json``)와
      정합한 4건 케이스(저상/일반·congestion 4종·remainingStops null/0/정수 등)를 포함한다.
    - 호출자가 임의 ``stop_id``를 넘겨도, mock은 stopId 필드만 호출자 값으로
      재기록하고 arrivals 배열은 mock 데이터를 그대로 사용한다 (4월 단순화).
    """

    def __init__(self, mock_path: Path | None = None):
        self.mock_path = mock_path or DEFAULT_MOCK_PATH

    def get_arrivals(self, stop_id: str) -> NormalizedBusArrivalsResponse:
        with self.mock_path.open(encoding="utf-8") as f:
            payload = json.load(f)
        # stopId만 호출자 값으로 덮어쓰고, arrivals는 mock 그대로 사용.
        # NormalizedBusArrivalsResponse는 extra='forbid'이므로 mock JSON에 비계약 필드가
        # 들어와 있으면 여기서 즉시 ValidationError로 실패한다 (의도된 안전장치).
        payload["stopId"] = stop_id
        return NormalizedBusArrivalsResponse.model_validate(payload)


class LiveBusArrivalsProvider:
    """실제 공공데이터 API를 호출해 표준 응답을 만드는 provider (skeleton).

    섹션 4에서는 (1) 환경변수와 클라이언트 결선, (2) 실패 케이스 분기 구조까지만
    잡아 두고, 실제 endpoint 호출과 원본 응답 normalize는 섹션 6 범위에서 구현한다.
    """

    def __init__(self, client: DataGoKrClient | None = None):
        self.client = client or DataGoKrClient()

    def get_arrivals(self, stop_id: str) -> NormalizedBusArrivalsResponse:
        # 1. 서비스키 빠른 실패 (PublicDataServiceKeyMissingError)
        self.client.require_service_key()

        # 2. 실제 endpoint 호출 — 섹션 6에서 구현.
        # 현재 단계에서는 명시적 NotImplementedError로 mock 미사용 시 실수를 막는다.
        # 호출자(BusArrivalsService)는 PUBLIC_DATA_USE_MOCK=false 일 때만 이 경로에 진입한다.
        raise NotImplementedError(
            "LiveBusArrivalsProvider.get_arrivals is not implemented yet. "
            "Implement this in 섹션 6 by calling DataGoKrClient with the appropriate "
            "endpoint (e.g. TAGO ArvlInfoInqireService) and normalizing the raw response "
            "into NormalizedBusArrivalsResponse. Until then, set PUBLIC_DATA_USE_MOCK=true."
        )

    # 섹션 6에서 구현할 helper들의 예고 시그니처 (각자 placeholder).
    def _call_arrivals_api(self, stop_id: str):  # pragma: no cover - skeleton
        """실제 도착 정보 API 호출. 섹션 6에서 구현.

        TAGO 또는 지자체 BIS 중 어떤 endpoint를 사용할지는 ``city_code``와
        활용신청 명세서 확보 여부에 따라 결정한다 (services/public_data/README.md 섹션 2 참고).
        """
        raise NotImplementedError

    def _normalize_arrivals(self, raw):  # pragma: no cover - skeleton
        """원본 응답 → ``list[NormalizedBusArrival]`` 변환. 섹션 6에서 구현.

        - busType: "0"=일반→False, "1"=저상→True, "2"=굴절→False
        - reride_Num: "0"=UNKNOWN, "3"=LOW, "4"=NORMAL, "5"=HIGH
        - 필드 부재 시 congestion=UNKNOWN, lowFloor 기본 정책은 섹션 6에서 확정
        """
        raise NotImplementedError


class BusArrivalsService:
    """정류장별 도착 정보 표준화 서비스의 단일 진입점."""

    def __init__(
        self,
        mock_provider: MockBusArrivalsProvider | None = None,
        live_provider: LiveBusArrivalsProvider | None = None,
        use_mock: bool | None = None,
    ):
        self.mock_provider = mock_provider or MockBusArrivalsProvider()
        # live_provider는 lazy 생성하지 않고 명시적으로 받거나 기본 인스턴스를 만든다.
        # mock 모드라면 live는 사용되지 않지만, 인스턴스 생성 자체는 부작용이 없으므로 OK.
        self.live_provider = live_provider or LiveBusArrivalsProvider()
        # 명시 인자가 우선. 미지정이면 호출 시점마다 환경변수를 평가해 hot reload를 허용.
        self._use_mock_override = use_mock

    @property
    def use_mock(self) -> bool:
        if self._use_mock_override is not None:
            return self._use_mock_override
        return _is_mock_mode()

    def get_arrivals(self, stop_id: str) -> NormalizedBusArrivalsResponse:
        """``stop_id`` 정류장의 표준화된 버스 도착 응답을 반환한다.

        반환값은 ``packages/shared_contracts/api/bus_arrivals.response.schema.json``
        ``BusArrivalsResponse`` 계약을 따른다.

        예외:
        - ``PublicDataServiceKeyMissingError`` : real 모드인데 서비스키 미설정
        - ``PublicDataNetworkError``           : real 모드 호출 실패 (섹션 6 이후)
        - ``PublicDataEmptyResponseError``     : 결과가 비어 normalize 불가 (섹션 6 이후 정책 확정 시)
        """
        if self.use_mock:
            return self.mock_provider.get_arrivals(stop_id)
        return self.live_provider.get_arrivals(stop_id)

    @staticmethod
    def empty_response(stop_id: str) -> NormalizedBusArrivalsResponse:
        """현재 운행 중인 버스가 없는 정류장에 대한 빈 응답 헬퍼.

        섹션 6에서 ``PublicDataEmptyResponseError`` 캐치 후 호출자가 빈 응답으로
        대체하고 싶을 때 사용 가능. updatedAt이 필요 없는 빈 arrivals 응답이라
        timezone-aware datetime 의존성이 없다.
        """
        return NormalizedBusArrivalsResponse(stopId=stop_id, arrivals=[])


# ---------------------------------------------------------------------------
# 사용 예시 — 모듈 import 시 자동 실행되지 않으며, 본 docstring은 참고용이다.
#
#   >>> service = BusArrivalsService()                  # 환경변수 기반 mock/real 선택
#   >>> resp = service.get_arrivals("mock-stop-001")    # NormalizedBusArrivalsResponse
#   >>> resp.stopId, len(resp.arrivals)
#   ('mock-stop-001', 4)
#
# 명시적 mock 강제:
#   >>> service = BusArrivalsService(use_mock=True)
#
# 명시적 real 강제 (섹션 6 이후에 의미가 있음):
#   >>> service = BusArrivalsService(use_mock=False)
#
# datetime/timezone 직접 사용 예시 (호출자 코드에서 Pydantic ValidationError 디버깅 시 참고):
#   >>> NormalizedBusArrival(
#   ...     routeId="r", busNo="b",
#   ...     arrivalMinutes=3, lowFloor=True,
#   ...     congestion=CongestionLevel.UNKNOWN,
#   ...     updatedAt=datetime.now(timezone.utc),
#   ... )
# ---------------------------------------------------------------------------
