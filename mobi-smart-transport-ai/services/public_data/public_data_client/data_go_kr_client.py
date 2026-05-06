import os

import httpx
from dotenv import load_dotenv

load_dotenv()


class DataGoKrClient:
    """공공데이터포털 API 클라이언트 skeleton.

    TODO(김도성):
    - 실제 API endpoint 조사 후 메서드 분리
    - 서비스키 URL encoding 처리
    - XML/JSON 응답 파싱
    - 호출 제한/오류 처리
    """

    def __init__(self, api_key: str | None = None, base_url: str | None = None):
        self.api_key = api_key or os.getenv("PUBLIC_DATA_API_KEY", "")
        self.base_url = base_url or os.getenv("PUBLIC_DATA_BASE_URL") or "https://apis.data.go.kr"
        self.client = httpx.Client(timeout=10)

    def get(self, path: str, params: dict[str, str]) -> httpx.Response:
        merged = {**params, "serviceKey": self.api_key}
        return self.client.get(f"{self.base_url}{path}", params=merged)
