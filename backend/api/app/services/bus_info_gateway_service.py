from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.schemas.bus_info import BusArrivalsResponse
from app.services.firebase_client import FirebaseClient, get_firebase_client


class BusInfoGatewayService:
    """김도성 public_data 표준 JSON과 FastAPI 사이의 읽기 전용 gateway.

    이 서비스는 공공데이터 API를 직접 호출하지 않는다. 우선 Firebase RTDB
    `/busArrivals/{stopId}`에 저장된 표준 응답을 조회하고, 없으면
    `services/public_data/examples/mock_bus_arrivals.json`을 읽기 전용 fallback으로 사용한다.
    김도성 모듈의 실제 provider-specific 필드와 호출 규칙은 김도성 섹션 6, 7 완료 후 연동한다.
    """

    FIREBASE_PATH_PREFIX = "/busArrivals"

    def __init__(
        self,
        *,
        firebase: FirebaseClient | None = None,
        mock_file_path: Path | None = None,
    ) -> None:
        self.firebase = firebase or get_firebase_client()
        self.mock_file_path = mock_file_path or self._default_mock_file_path()

    def get_arrivals(self, stop_id: str) -> BusArrivalsResponse:
        """Return normalized bus arrival data without calling public data APIs."""
        cached = self.firebase.get(self._firebase_path(stop_id))
        if cached is not None:
            return self._coerce_response(cached, fallback_stop_id=stop_id)

        mock_response = self._read_mock_response()
        if mock_response and mock_response.stopId == stop_id:
            return mock_response

        return BusArrivalsResponse(stopId=stop_id, arrivals=[])

    def save_arrivals(self, response: BusArrivalsResponse) -> None:
        """Store already-normalized arrivals at `/busArrivals/{stopId}`.

        This is a gateway storage interface only. It does not fetch, normalize,
        or enrich provider-specific public data fields.
        """
        payload = response.model_dump(mode="json")
        self.firebase.set(self._firebase_path(response.stopId), payload)

    def _firebase_path(self, stop_id: str) -> str:
        return f"{self.FIREBASE_PATH_PREFIX}/{stop_id}"

    @staticmethod
    def _now_utc() -> datetime:
        """Keep gateway timestamp generation centralized for future cache writes."""
        return datetime.now(timezone.utc)

    def _read_mock_response(self) -> BusArrivalsResponse | None:
        if not self.mock_file_path.exists():
            return None
        data = json.loads(self.mock_file_path.read_text(encoding="utf-8"))
        return self._coerce_response(data)

    def _coerce_response(self, data: Any, *, fallback_stop_id: str | None = None) -> BusArrivalsResponse:
        if isinstance(data, list):
            data = {"stopId": fallback_stop_id, "arrivals": data}
        if isinstance(data, dict) and "stopId" not in data and fallback_stop_id:
            data = {**data, "stopId": fallback_stop_id}
        return BusArrivalsResponse.model_validate(data)

    @staticmethod
    def _default_mock_file_path() -> Path:
        current = Path(__file__).resolve()
        for parent in current.parents:
            candidate = parent / "services" / "public_data" / "examples" / "mock_bus_arrivals.json"
            if candidate.exists():
                return candidate
        return current.parents[4] / "services" / "public_data" / "examples" / "mock_bus_arrivals.json"
