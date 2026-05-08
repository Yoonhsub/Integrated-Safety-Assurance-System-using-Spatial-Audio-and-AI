"""공공데이터포털 API 클라이언트 skeleton.

이 모듈은 김도성 담당 services/public_data 영역의 HTTP 클라이언트 경계이다.
backend/api나 Flutter 앱은 이 모듈을 직접 호출하지 않으며,
호출은 항상 ``BusArrivalsService`` 등 services/public_data 내부 서비스 레이어를 통해 한다.

환경변수:
- ``PUBLIC_DATA_API_KEY``    : 공공데이터포털 서비스키. 미설정 시 호출 시점에 ``PublicDataServiceKeyMissingError``.
- ``PUBLIC_DATA_BASE_URL``   : 기본 URL. 기본값 ``https://apis.data.go.kr``.
- ``PUBLIC_DATA_CITY_CODE``  : TAGO 등 ``cityCode`` 파라미터가 필요한 API에서 사용. 빈 값이면 None.
- ``PUBLIC_DATA_USE_MOCK``   : 이 클라이언트가 직접 평가하지 않는다. 평가 책임은 ``BusArrivalsService``에 있다.

설계 원칙:
- ``DataGoKrClient``는 transport-only 계층이다. 응답을 NormalizedBusArrivalsResponse로
  변환하지 않고, ``httpx.Response`` 또는 ``RawArrivalItem`` 같은 원본 형태만 다룬다.
- normalize는 ``BusArrivalsService`` 또는 별도 normalize 함수가 책임진다 (섹션 6).
- 예외는 ``services/public_data/public_data_client/exceptions.py``의 계층을 사용한다.

TODO(김도성, 섹션 6):
- 실제 endpoint(예: TAGO ``/1613000/ArvlInfoInqireService/getSttnAcctoArvlPrearngeInfoList``)
  와 매개변수(``cityCode``, ``nodeId`` 등)를 별도 메서드로 분리한다.
- XML/JSON 응답 파싱.
- 호출 제한, 일시 오류 retry/backoff (운영 단계).
"""

from __future__ import annotations

import os

import httpx
from dotenv import load_dotenv

from .exceptions import (
    PublicDataNetworkError,
    PublicDataServiceKeyMissingError,
)

load_dotenv()

DEFAULT_BASE_URL = "https://apis.data.go.kr"
DEFAULT_TIMEOUT_SECONDS = 10.0


class DataGoKrClient:
    """공공데이터포털 API 클라이언트 skeleton (transport-only 계층)."""

    def __init__(
        self,
        api_key: str | None = None,
        base_url: str | None = None,
        city_code: str | None = None,
        timeout: float = DEFAULT_TIMEOUT_SECONDS,
    ):
        # 우선순위: 명시 인자 > 환경변수 > 기본값
        self.api_key: str = api_key if api_key is not None else os.getenv("PUBLIC_DATA_API_KEY", "")
        self.base_url: str = (
            base_url
            if base_url is not None
            else (os.getenv("PUBLIC_DATA_BASE_URL") or DEFAULT_BASE_URL)
        )
        # 빈 문자열은 None으로 정규화한다 (.env.example의 ``PUBLIC_DATA_CITY_CODE=`` 케이스 대응)
        raw_city = city_code if city_code is not None else os.getenv("PUBLIC_DATA_CITY_CODE", "")
        self.city_code: str | None = raw_city if raw_city else None
        self.client = httpx.Client(timeout=timeout)

    def has_service_key(self) -> bool:
        """서비스키가 설정되어 있는지(빈 문자열도 미설정으로 간주)."""
        return bool(self.api_key)

    def require_service_key(self) -> None:
        """서비스키가 없으면 ``PublicDataServiceKeyMissingError``를 발생시킨다.

        호출자(BusArrivalsService 등)는 mock 모드가 아니라고 판단했을 때
        실제 호출 직전에 이 메서드를 호출해 빠르게 실패시킬 수 있다.
        """
        if not self.has_service_key():
            raise PublicDataServiceKeyMissingError(
                "PUBLIC_DATA_API_KEY is not set. "
                "Set the environment variable, or use mock mode by setting "
                "PUBLIC_DATA_USE_MOCK=true."
            )

    def get(self, path: str, params: dict[str, str] | None = None) -> httpx.Response:
        """GET 호출. ``serviceKey``는 자동으로 합쳐 보낸다.

        - 서비스키 누락 시 ``PublicDataServiceKeyMissingError``.
        - 네트워크/타임아웃/HTTP 오류 시 ``PublicDataNetworkError``.
          (HTTP 비-2xx도 네트워크 실패와 동일 분류로 잡고, 호출자가 응답 본문이
          필요하면 ``raise_for_status``를 끄는 형태로 별도 메서드를 도입한다 — 섹션 6 후보.)
        """
        self.require_service_key()

        merged: dict[str, str] = {**(params or {}), "serviceKey": self.api_key}
        url = f"{self.base_url}{path}"
        try:
            response = self.client.get(url, params=merged)
            response.raise_for_status()
            return response
        except httpx.HTTPError as exc:
            # httpx.TimeoutException, httpx.RequestError, httpx.HTTPStatusError 모두 포함
            raise PublicDataNetworkError(
                f"public data API call failed for {path}: {exc.__class__.__name__}"
            ) from exc

    def close(self) -> None:
        """장기 실행 컨텍스트에서 명시적으로 클라이언트를 닫고 싶을 때 사용."""
        self.client.close()

    def __enter__(self) -> "DataGoKrClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

