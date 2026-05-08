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
        # client는 lazy 생성한다. mock 모드에서 LiveBusArrivalsProvider 인스턴스만
        # 만들어지고 실제 호출이 없는 흔한 경우, httpx.Client 같은 부작용을 만들지 않기 위함이다.
        # _get_client()가 처음 호출될 때 비로소 DataGoKrClient(=httpx.Client)가 만들어진다.
        self._client_override = client
        self._lazy_client: DataGoKrClient | None = None

    def _get_client(self) -> DataGoKrClient:
        if self._client_override is not None:
            return self._client_override
        if self._lazy_client is None:
            self._lazy_client = DataGoKrClient()
        return self._lazy_client

    @property
    def client(self) -> DataGoKrClient:
        """기존 ``self.client`` 접근 호환을 위한 lazy property."""
        return self._get_client()

    def get_arrivals(self, stop_id: str) -> NormalizedBusArrivalsResponse:
        # 1. 서비스키 빠른 실패 (PublicDataServiceKeyMissingError)
        self.client.require_service_key()

        # 2. 실제 endpoint 호출 — 4월 단계는 명세 미확보(TAGO) + 신규 인증키 발급 불가(서울 BIS)
        # 운영 환경이라 호출 본체를 stub으로 유지한다. 명세서 확보 후 섹션 8 또는 10에서
        # _call_arrivals_api 본체를 구현하면 본 메서드는 다음 흐름으로 동작한다:
        #
        #     raw_items = self._call_arrivals_api(stop_id)
        #     if not raw_items:
        #         raise PublicDataEmptyResponseError(...)  # 또는 빈 응답 정책
        #     normalized = self._normalize_arrivals(raw_items)
        #     return NormalizedBusArrivalsResponse(stopId=stop_id, arrivals=normalized)
        raise NotImplementedError(
            "LiveBusArrivalsProvider.get_arrivals call body is not implemented yet. "
            "Activate by implementing _call_arrivals_api against the operative API "
            "(TAGO ArvlInfoInqireService once the field spec is confirmed, or 서울 BIS "
            "getArrInfoByRouteAll once an authentication key is available). "
            "Until then, set PUBLIC_DATA_USE_MOCK=true."
        )

    def _call_arrivals_api(self, stop_id: str):  # pragma: no cover - skeleton
        """실제 도착 정보 API 호출 (섹션 8 또는 10에서 구현).

        구현 시:
        - ``self.client.city_code``가 비어 있지 않으면 TAGO 호출 (cityCode/nodeId).
        - 비어 있으면 서울 BIS 등 단일 도시 BIS 호출.
        - 호출 실패는 ``PublicDataNetworkError`` (이미 ``DataGoKrClient.get``이 변환).
        - 응답이 비면 호출자(get_arrivals)가 ``PublicDataEmptyResponseError`` 또는
          빈 arrivals 정책에 따라 처리.
        """
        raise NotImplementedError

    def _normalize_arrivals(
        self,
        raw_items: list[dict],
    ) -> list[NormalizedBusArrival]:
        """원본 응답 항목 list → 표준 ``NormalizedBusArrival`` list 변환.

        매핑 규칙(서울 BIS ``getArrInfoByRouteAll`` 응답 필드 기준 — 1차 출처는
        ``services/public_data/README.md`` 섹션 2 참조):

        - ``rtNm`` 또는 ``busRouteId`` → ``routeId`` (없으면 빈 문자열로 두지 않고 호출자 책임)
        - ``busRouteAbrv`` 또는 ``rtNm`` → ``busNo`` (안내용 노선명 우선)
        - ``exps1`` 초 → ``arrivalMinutes`` (``round(seconds / 60)``)
        - ``staOrd`` 또는 별도 필드 → ``remainingStops`` (없으면 ``None``)
        - ``busType1`` "1" → ``lowFloor=True``, "0"/"2" → ``False``, 그 외 → ``False`` (안전 기본)
        - ``reride_Num1`` → ``congestion`` (0/3/4/5 → UNKNOWN/LOW/NORMAL/HIGH, 그 외 → UNKNOWN)
        - ``updatedAt`` → 호출 시점의 timezone-aware UTC datetime을 일괄 적용
          (서울 BIS는 응답에 별도 timestamp를 정확히 제공하지 않아 호출 시점을 사용)

        본 메서드는 ``raw_items``의 각 dict가 위 키를 갖는다고 가정한다. 키 누락 시:
        - 필수 필드 누락 → ``KeyError``를 호출자에 전파 (호출자가 ``PublicDataEmptyResponseError``로 변환)
        - 선택 필드 누락 → 안전 기본값으로 흡수

        TAGO ``ArvlInfoInqireService``의 응답 필드명은 활용신청 명세서 확인 후
        본 메서드의 키 set을 조건 분기로 확장한다. 4월 단계에서는 서울 BIS 키 셋을 가정.
        """
        from datetime import datetime, timezone

        from .normalize import (
            map_reride_to_congestion,
            map_vehicle_type_to_low_floor,
            seconds_to_arrival_minutes,
        )

        now = datetime.now(timezone.utc)
        results: list[NormalizedBusArrival] = []
        for item in raw_items:
            # 노선 식별 — DB관리용 rtNm을 routeId로, 안내용 busRouteAbrv를 busNo로
            route_id = str(item.get("rtNm") or item.get("busRouteId") or "")
            bus_no = str(item.get("busRouteAbrv") or item.get("rtNm") or route_id or "")

            # 도착 예정 시간 — 첫번째 도착예정 차량 exps1 사용
            raw_secs = item.get("exps1")
            if raw_secs is None:
                # 일부 응답에서 exps1 대신 다른 필드명일 수 있음 (kals1 등). 그 외는 0 처리.
                raw_secs = item.get("kals1") or 0
            arrival_minutes = seconds_to_arrival_minutes(raw_secs)

            # 남은 정류장 수 (서울 BIS는 도착예정 차량 기준 staOrd 또는 nstnId 거리 — 4월은 옵션)
            remaining_stops = item.get("staOrd")
            if remaining_stops is not None:
                try:
                    remaining_stops = int(remaining_stops)
                    if remaining_stops < 0:
                        remaining_stops = None
                except (TypeError, ValueError):
                    remaining_stops = None

            # 저상버스 — 미상은 False로 흡수 (README §4 정책: 저상이 확실한 경우만 True)
            low_floor = map_vehicle_type_to_low_floor(item.get("busType1"), default=False)
            assert low_floor is not None  # default=False라 None은 나오지 않음

            # 혼잡도 — 미제공이면 UNKNOWN
            congestion = map_reride_to_congestion(item.get("reride_Num1"))

            results.append(
                NormalizedBusArrival(
                    routeId=route_id,
                    busNo=bus_no,
                    arrivalMinutes=arrival_minutes,
                    remainingStops=remaining_stops,
                    lowFloor=low_floor,
                    congestion=congestion,
                    updatedAt=now,
                )
            )

        return results


class BusArrivalsService:
    """정류장별 도착 정보 표준화 서비스의 단일 진입점."""

    def __init__(
        self,
        mock_provider: MockBusArrivalsProvider | None = None,
        live_provider: LiveBusArrivalsProvider | None = None,
        use_mock: bool | None = None,
    ):
        self.mock_provider = mock_provider or MockBusArrivalsProvider()
        # live_provider도 lazy 생성한다. mock 모드에서 BusArrivalsService를 만들 때
        # ``LiveBusArrivalsProvider`` → ``DataGoKrClient`` → ``httpx.Client`` 체인이 즉시
        # 만들어져 사용되지 않을 file descriptor를 잡는 부작용을 막는다.
        # ``self.live_provider`` 접근 시점에 비로소 인스턴스가 만들어진다.
        self._live_provider_override = live_provider
        self._lazy_live_provider: LiveBusArrivalsProvider | None = None
        # 명시 인자가 우선. 미지정이면 호출 시점마다 환경변수를 평가해 hot reload를 허용.
        self._use_mock_override = use_mock

    @property
    def live_provider(self) -> LiveBusArrivalsProvider:
        """real 모드에서 처음 사용될 때만 ``LiveBusArrivalsProvider``를 만든다."""
        if self._live_provider_override is not None:
            return self._live_provider_override
        if self._lazy_live_provider is None:
            self._lazy_live_provider = LiveBusArrivalsProvider()
        return self._lazy_live_provider

    @property
    def use_mock(self) -> bool:
        if self._use_mock_override is not None:
            return self._use_mock_override
        return _is_mock_mode()

    def get_arrivals(self, stop_id: str) -> NormalizedBusArrivalsResponse:
        """``stop_id`` 정류장의 표준화된 버스 도착 응답을 반환한다.

        반환값은 ``packages/shared_contracts/api/bus_arrivals.response.schema.json``
        ``BusArrivalsResponse`` 계약을 따른다.

        빈 응답 정책 (섹션 6 확정):
        - real provider가 ``PublicDataEmptyResponseError``를 raise하면 본 메서드가
          이를 catch하여 빈 ``arrivals`` 정상 응답으로 변환한다. 호출자(UI/백엔드)는
          "현재 운행 중인 버스가 없는 정류장"을 빈 list로 자연스럽게 처리할 수 있다.
        - 그 외 ``PublicDataError`` 계열(``ServiceKeyMissing``/``Network``)은 호출자에
          그대로 전파한다.

        예외:
        - ``PublicDataServiceKeyMissingError`` : real 모드인데 서비스키 미설정
        - ``PublicDataNetworkError``           : real 모드 호출 실패
        """
        if self.use_mock:
            return self.mock_provider.get_arrivals(stop_id)
        try:
            return self.live_provider.get_arrivals(stop_id)
        except PublicDataEmptyResponseError:
            # 빈 응답을 정상 출력으로 변환. 호출자는 빈 arrivals를 자연스럽게 처리.
            return self.empty_response(stop_id)

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
