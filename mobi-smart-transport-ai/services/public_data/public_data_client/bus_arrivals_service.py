"""정류장별 도착 정보 표준화 서비스 skeleton.

이 모듈은 외부 호출자(현재는 동일 services/public_data 내부 사용 예시,
향후 심현석 백엔드)가 사용할 단일 진입점이다.
호출자는 ``BusArrivalsService().get_arrivals(stop_id)``를 호출하면
``NormalizedBusArrivalsResponse``(=``BusArrivalsResponse`` 공식 계약)를 돌려받는다.

mock/real 경계는 ``PUBLIC_DATA_USE_MOCK`` 환경변수가 결정한다.
- ``PUBLIC_DATA_USE_MOCK=true``  (또는 미설정): mock 응답 사용. 4월 MVP 기본.
- ``PUBLIC_DATA_USE_MOCK=false``               : real provider 사용 (README §V2 섹션 1 §6 활성화 절차 참조).

설계 책임 분리:
- ``DataGoKrClient``       : transport-only. HTTP 호출과 예외 변환.
- ``MockBusArrivalsProvider`` : mock JSON 파일을 읽어 표준 모델로 변환.
- ``LiveBusArrivalsProvider`` : 실제 API 호출 + 원본 응답 normalize (활성화 시점에 구현).
- ``BusArrivalsService``    : 환경변수 기반 disp + 호출자 진입점.

V2 미구현 사항 (2학기 활성화 시점):
- ``LiveBusArrivalsProvider._call_arrivals_api`` 실제 endpoint 호출 구현.
- 원본 응답 → ``NormalizedBusArrival`` 변환은 V2 섹션 3에서 TAGO 키 셋 분기로 정밀화됨.
- 빈 응답 → ``BusArrivalsService.get_arrivals``가 ``PublicDataEmptyResponseError`` catch 후 빈 ``arrivals`` 정상 응답 반환 (V2 섹션 3 정밀화).
- 저상버스 우선 정렬/필터 → ``low_floor_filter.py`` V2 섹션 5에서 ``AccessibilityMode`` 4종 + ``apply_accessibility_filter`` dispatch 구현 완료.
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
        # 운영 환경이라 호출 본체를 stub으로 유지한다. 명세서 확보 후 2학기 단계에서
        # _call_arrivals_api 본체를 구현하면 본 메서드는 다음 흐름으로 동작한다:
        #
        #     raw_items = self._call_arrivals_api(stop_id)
        #     if not raw_items:
        #         raise PublicDataEmptyResponseError(...)  # 또는 빈 응답 정책
        #     normalized = self._normalize_arrivals(raw_items)
        #     return NormalizedBusArrivalsResponse(stopId=stop_id, arrivals=normalized)
        raw_items = self._call_arrivals_api(stop_id)
        if not raw_items:
            raise PublicDataEmptyResponseError(f"No arrivals found for stop_id: {stop_id}")
        normalized = self._normalize_arrivals(raw_items)
        return NormalizedBusArrivalsResponse(stopId=stop_id, arrivals=normalized)

    def _call_arrivals_api(self, stop_id: str):  # pragma: no cover - skeleton
        """실제 도착 정보 API 호출 (섹션 10 boilerplate, 본격 활성화는 명세 확보 후).

        본 메서드는 4월 단계에서 **호출 본체가 stub으로 유지**된다. 그 이유는:

        1. 서울 BIS ``getArrInfoByRouteAll``의 응답 필드명은 README 섹션 2에서 1차 출처로
           확인했지만, 4월 김도성 환경에서 인증키를 즉시 확보할 보장이 없다. 공공데이터포털
           인증키 발급 자체는 정상화되었으나(국가정보자원관리원 화재 후 위기경보 '경계'→'주의'
           하향, 대구센터 PPP 이전으로 복구 진행 중), 캡스톤 학생 환경에서 발급 대기·트래픽
           제약(개발계정 1일 1,000건)을 감수하기보다 mock 모드를 4월 MVP 기본으로 둔다.
        2. TAGO ``ArvlInfoInqireService``의 ``vehicletp`` / 혼잡도 필드 명세는 활용신청
           명세서 수령 후에 확정 가능.

        본 boilerplate가 보여주는 것:
        - 호출 시그니처(URL path / 매개변수 / 응답 형식)가 운영 환경에서 어떻게 생겨야 하는지.
        - ``self.client.city_code`` 분기로 TAGO/서울 BIS 중 어느 endpoint를 부를지 결정.
        - 응답 파싱(XML → ``list[dict]``)은 ``_normalize_arrivals``가 받는 raw_items 형식과
          연결.

        명세 확보 후 활성화 절차:
        1. ``PUBLIC_DATA_API_KEY`` 환경변수에 발급받은 서비스키 설정 (코드/ZIP에 키 포함 금지).
        2. ``PUBLIC_DATA_USE_MOCK=false`` 로 mock 모드 해제.
        3. 본 메서드의 ``raise NotImplementedError`` 줄을 제거하고 그 아래 boilerplate
           코드를 활성화 (현재는 ``return`` 직전에서 멈춤).

        Returns:
            list[dict]: 서울 BIS getArrInfoByRouteAll 응답 형식의 raw items 리스트.
                각 dict는 ``rtNm`` / ``busRouteAbrv`` / ``exps1`` / ``staOrd`` /
                ``busType1`` / ``reride_Num1`` 등의 키를 가질 수 있다 (서울 BIS 명세 기준).
                ``_normalize_arrivals``의 입력으로 그대로 전달된다.

        Raises:
            NotImplementedError: 4월 단계 기본. 명세 확보 후 활성화 시 제거.
            PublicDataNetworkError: 활성화 후 네트워크/HTTP 실패 시 (DataGoKrClient.get이 변환).
        """
        # TAGO API (다도시 표준)
        # cityCode는 기본적으로 Cheongju(33010)으로 설정되어 있다고 가정하거나 
        # self.client.city_code가 있으면 사용합니다.
        city_code = self.client.city_code or "33010"
        path = "/1613000/ArvlInfoInqireService/getSttnAcctoArvlPrearngeInfoList"
        params: dict[str, str] = {
            "cityCode": city_code,
            "nodeId": stop_id,
            "_type": "json",
            "numOfRows": "30",
            "pageNo": "1",
        }

        # DataGoKrClient.get이 내부적으로 serviceKey를 병합하고 에러를 변환합니다.
        # 주의: DataGoKrClient의 기본 base_url이 'https://apis.data.go.kr' 입니다.
        # 만약 PUBLIC_DATA_BASE_URL 환경변수가 'https://api.odcloud.kr/api' 라면 
        # TAGO API를 호출할 때는 'https://apis.data.go.kr' 로 강제 지정해야 할 수 있습니다.
        # 임시로 강제로 TAGO base_url을 지정합니다.
        original_base_url = self.client.base_url
        if "odcloud" in original_base_url:
            self.client.base_url = "https://apis.data.go.kr"
        
        try:
            response = self.client.get(path, params=params)
        finally:
            self.client.base_url = original_base_url

        content_type = response.headers.get("content-type", "").lower()
        if "json" in content_type:
            payload = response.json()
            items = payload.get("response", {}).get("body", {}).get("items")
            if not items or isinstance(items, str):
                return []
            item_list = items.get("item", [])
            items = item_list if isinstance(item_list, list) else [item_list]
        else:
            import xml.etree.ElementTree as ET
            try:
                root = ET.fromstring(response.text)
                items = [
                    {child.tag: child.text for child in item}
                    for item in root.findall(".//item")
                ]
            except ET.ParseError:
                items = []
        
        if isinstance(items, dict):
            items = [items]
            
        return items

    def _normalize_arrivals(
        self,
        raw_items: list[dict],
    ) -> list[NormalizedBusArrival]:
        """원본 응답 항목 list → 표준 ``NormalizedBusArrival`` list 변환.

        V2 섹션 3 정밀화 기준: 매핑 규칙을 **공식 1차 출처에 명시된 필드명**으로
        정렬하고, **다중 도시 API 키 셋을 분기 처리**한다. 4월 V1 단계에서는 서울 BIS
        키 셋만 가정했으나, V2 단계에서는 TAGO 키 셋도 fallback으로 처리해 청주/대전
        등 다도시 환경에서도 그대로 동작 가능.

        매핑 규칙 (V2):

        - ``routeId`` (DB 관리용 식별자)
          - 서울 BIS: ``rtNm`` → fallback ``busRouteId``
          - TAGO   : ``routeId`` → fallback ``routeNo``
        - ``busNo`` (사용자 안내용 노선명)
          - 서울 BIS: ``busRouteAbrv`` → fallback ``rtNm``
          - TAGO   : ``routeNo`` → fallback ``routeId``
        - ``arrivalMinutes`` (분 단위 정수)
          - 서울 BIS: ``exps1`` (초) → fallback ``kals1``
          - TAGO   : ``arrtime`` (초) 단일 키
          - 변환: ``round(seconds / 60)`` — Python banker's rounding 적용
        - ``remainingStops`` (남은 정류장 수, 선택)
          - 서울 BIS: ``staOrd`` (해당 차량 기준 잔여 정거장 수)
          - TAGO   : 미제공 → ``None``
          - 음수 또는 변환 실패 시 ``None`` 흡수
        - ``lowFloor`` (저상버스 여부, 필수 bool)
          - 서울 BIS: ``busType1`` (0/1/2 코드, 1 → True)
          - TAGO   : ``vehicletp`` (저상버스 코드 — 명세 미확정, 활성화 후 조정)
          - 미상 → ``False`` 안전 기본 (README §4 정책: 저상이 확실한 경우만 True)
        - ``congestion`` (혼잡도 enum 4종)
          - 서울 BIS: ``reride_Num1`` (0/3/4/5 → UNKNOWN/LOW/NORMAL/HIGH)
          - TAGO   : 미제공 → ``UNKNOWN``
          - 그 외 값 → ``UNKNOWN``
        - ``updatedAt`` (RFC3339 datetime, 필수)
          - 응답에 timestamp가 있으면 그것을 우선 사용:
            - 서울 BIS: ``createdAt`` 등 timestamp 필드 (있을 때만)
            - TAGO   : ``createdAt`` 등 (있을 때만)
          - 응답에 timestamp가 없으면 호출 시점의 timezone-aware UTC datetime 일괄 적용
          - 결과는 항상 timezone-aware (UTC). JSON 직렬화 시 ``YYYY-MM-DDTHH:MM:SS+00:00``
            형식으로 출력되어 shared schema ``format: date-time`` (RFC3339) 정합.

        본 메서드는 ``raw_items``의 각 dict가 위 키를 갖는다고 가정한다. 키 누락 시:

        - 필수 필드 누락 (``routeId``/``busNo`` 모두 추출 실패) → 안전하게 빈 문자열로
          두고 호출자가 후속 검증에서 거르도록 함 (Pydantic ``StrictPublicDataModel``의
          ``extra='forbid'`` + 필수 필드 검증은 통과하므로 빈 문자열 자체는 valid).
        - 선택 필드 누락 (``remainingStops`` 등) → 안전 기본값으로 흡수.

        ``raw_items``가 빈 list일 경우:

        - 본 메서드는 빈 list ``[]``를 그대로 반환 (예외 발생하지 않음).
        - 빈 응답을 ``PublicDataEmptyResponseError``로 분리할지는 호출자
          (LiveBusArrivalsProvider) 정책. ``BusArrivalsService.get_arrivals``가
          최종적으로 빈 ``arrivals``를 정상 응답으로 변환.

        TAGO ``ArvlInfoInqireService`` 활성화 시점에 응답 필드명이 본 메서드의
        TAGO 키 셋과 다르면 키 set을 조정한다. 활성화 절차는
        ``services/public_data/README.md`` §V2 섹션 1 §6 참조.
        """
        from datetime import datetime, timezone

        from .normalize import (
            map_reride_to_congestion,
            map_vehicle_type_to_low_floor,
            seconds_to_arrival_minutes,
        )

        # 빈 raw_items는 빈 결과 그대로 반환 (호출자가 PublicDataEmptyResponseError로 분리)
        if not raw_items:
            return []

        now = datetime.now(timezone.utc)
        results: list[NormalizedBusArrival] = []
        for item in raw_items:
            # 노선 식별 (서울 BIS → TAGO 순 fallback)
            # TAGO 응답은 키가 소문자(routeid/routeno)이므로 camelCase 키 뒤에 함께 시도한다.
            route_id = str(
                item.get("rtNm")
                or item.get("busRouteId")
                or item.get("routeId")
                or item.get("routeid")
                or item.get("routeNo")
                or item.get("routeno")
                or ""
            )
            bus_no = str(
                item.get("busRouteAbrv")
                or item.get("rtNm")
                or item.get("routeNo")
                or item.get("routeno")
                or route_id
                or ""
            )

            # 도착 예정 시간 (서울 BIS exps1/kals1 → TAGO arrtime)
            raw_secs = item.get("exps1")
            if raw_secs is None:
                raw_secs = item.get("kals1")
            if raw_secs is None:
                raw_secs = item.get("arrtime")  # TAGO key
            if raw_secs is None:
                raw_secs = 0
            arrival_minutes = seconds_to_arrival_minutes(raw_secs)

            # 남은 정류장 수 (서울 BIS staOrd → TAGO arrprevstationcnt)
            remaining_stops = item.get("staOrd")
            if remaining_stops is None:
                remaining_stops = item.get("arrprevstationcnt")  # TAGO key
            if remaining_stops is not None:
                try:
                    remaining_stops = int(remaining_stops)
                    if remaining_stops < 0:
                        remaining_stops = None
                except (TypeError, ValueError):
                    remaining_stops = None

            # 저상버스 — 미상은 False로 흡수 (README §4 정책)
            # 서울 BIS busType1 → TAGO vehicletp (명세 미확정, 활성화 후 조정)
            low_floor_raw = item.get("busType1")
            if low_floor_raw is None:
                low_floor_raw = item.get("vehicletp")  # TAGO key (활성화 후 조정 가능)
            low_floor = map_vehicle_type_to_low_floor(low_floor_raw, default=False)
            assert low_floor is not None  # default=False라 None은 나오지 않음

            # 혼잡도 — 미제공이면 UNKNOWN
            # 서울 BIS reride_Num1 → TAGO는 혼잡도 필드 미제공이므로 UNKNOWN 흡수
            congestion = map_reride_to_congestion(item.get("reride_Num1"))

            # updatedAt — 응답 timestamp가 있으면 우선 사용, 없으면 호출 시점
            # 4월 V1 단계에서는 호출 시점 일괄 적용했고, V2 단계에서는 응답 timestamp
            # 우선 정책을 명시적으로 둠. 단 현재 서울 BIS/TAGO 응답은 표준 timestamp
            # 필드가 명확하지 않아 응답에서 추출 가능한 경우만 사용하고, 그 외는
            # 호출 시점으로 fallback.
            updated_at = now
            ts_raw = item.get("createdAt") or item.get("responseTime")
            if ts_raw:
                try:
                    parsed = datetime.fromisoformat(str(ts_raw))
                    if parsed.tzinfo is None:
                        parsed = parsed.replace(tzinfo=timezone.utc)
                    updated_at = parsed
                except (TypeError, ValueError):
                    # 파싱 실패 시 호출 시점 fallback (silent)
                    updated_at = now

            results.append(
                NormalizedBusArrival(
                    routeId=route_id,
                    busNo=bus_no,
                    arrivalMinutes=arrival_minutes,
                    remainingStops=remaining_stops,
                    lowFloor=low_floor,
                    congestion=congestion,
                    updatedAt=updated_at,
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

        섹션 3 정밀화에서 ``PublicDataEmptyResponseError`` 캐치 후 호출자가 빈 응답으로
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
