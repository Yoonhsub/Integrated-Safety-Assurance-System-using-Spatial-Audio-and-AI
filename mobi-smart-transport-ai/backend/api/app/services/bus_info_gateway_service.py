from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.schemas.bus_info import BusArrivalsResponse
from app.services.firebase_client import FirebaseClient, get_firebase_client


def _ensure_project_root_on_path() -> None:
    current = Path(__file__).resolve()
    for parent in current.parents:
        if (parent / "services" / "public_data" / "public_data_client").exists():
            root = str(parent)
            if root not in sys.path:
                sys.path.insert(0, root)
            return


_ensure_project_root_on_path()

from services.public_data.public_data_client.bus_arrivals_service import BusArrivalsService  # noqa: E402


class BusInfoGatewayService:
    """김도성 public_data 표준 응답과 FastAPI 사이의 읽기 전용 gateway.

    이 서비스는 provider-specific 원본 필드를 직접 해석하지 않는다. 우선 Firebase RTDB
    `/busArrivals/{stopId}`에 저장된 표준 응답을 조회하고, 없으면 김도성 public_data
    모듈의 확정 진입점 `BusArrivalsService.get_arrivals(stop_id)`에서 표준 응답을 받는다.
    """

    FIREBASE_PATH_PREFIX = "/busArrivals"

    def __init__(
        self,
        *,
        firebase: FirebaseClient | None = None,
        public_data_service: BusArrivalsService | None = None,
    ) -> None:
        self.firebase = firebase or get_firebase_client()
        self.public_data_service = public_data_service or BusArrivalsService()

    def get_arrivals(self, stop_id: str) -> BusArrivalsResponse:
        """Return normalized bus arrival data without parsing provider raw fields."""
        cached = self.firebase.get(self._firebase_path(stop_id))
        if cached is not None:
            return self._coerce_response(cached, fallback_stop_id=stop_id)

        public_data_response = self.public_data_service.get_arrivals(stop_id)
        return self._coerce_response(public_data_response, fallback_stop_id=stop_id)

    def save_arrivals(self, response: BusArrivalsResponse) -> None:
        """Store already-normalized arrivals at `/busArrivals/{stopId}`.

        This is a gateway storage interface only. It does not fetch, normalize,
        or enrich provider-specific public data fields.
        """
        payload = response.model_dump(mode="json")
        self.firebase.set(self._firebase_path(response.stopId), payload)

    def _firebase_path(self, stop_id: str) -> str:
        return f"{self.FIREBASE_PATH_PREFIX}/{stop_id}"

    def _coerce_response(self, data: Any, *, fallback_stop_id: str | None = None) -> BusArrivalsResponse:
        if hasattr(data, "model_dump"):
            data = data.model_dump(mode="json")
        if isinstance(data, list):
            data = {"stopId": fallback_stop_id, "arrivals": data}
        if isinstance(data, dict) and "stopId" not in data and fallback_stop_id:
            data = {**data, "stopId": fallback_stop_id}
        data = self._ensure_arrival_timestamps(data)
        return BusArrivalsResponse.model_validate(data)

    def _ensure_arrival_timestamps(self, data: Any) -> Any:
        if not isinstance(data, dict) or not isinstance(data.get("arrivals"), list):
            return data

        now = datetime.now(timezone.utc)
        arrivals = [
            {**arrival, "updatedAt": arrival.get("updatedAt") or now}
            if isinstance(arrival, dict)
            else arrival
            for arrival in data["arrivals"]
        ]
        return {**data, "arrivals": arrivals}
