from __future__ import annotations

import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from fastapi import HTTPException

from app.schemas.bus_info import BusArrivalsResponse
from app.services.firebase_client import FirebaseClient, get_firebase_client


BusInfoFallbackSource = Literal["CACHE", "PUBLIC_API", "MOCK"]


@dataclass(frozen=True)
class BusInfoGatewayResult:
    response: BusArrivalsResponse
    source: BusInfoFallbackSource


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
    """Read-only gateway between FastAPI and normalized public bus-arrival data.

    The gateway checks the Firebase RTDB cache first. On cache miss it delegates to
    ``services/public_data`` and records whether the result came from a live public
    API path or the public_data mock provider. Provider-specific raw fields are not
    parsed in this backend layer.
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
        """Return normalized bus arrival data without exposing fallback metadata.

        Kept for the existing V2 ``/bus-info`` contract.
        """
        return self.get_arrivals_with_source(stop_id).response

    def get_arrivals_with_source(self, stop_id: str) -> BusInfoGatewayResult:
        """Return normalized arrivals with the source used by V3 fallback logic."""
        normalized_stop_id = self._normalize_stop_id(stop_id)

        cached = self.firebase.get(self._firebase_path(normalized_stop_id))
        if cached is not None:
            return BusInfoGatewayResult(
                response=self._coerce_response(cached, fallback_stop_id=normalized_stop_id),
                source="CACHE",
            )

        try:
            public_data_response = self.public_data_service.get_arrivals(normalized_stop_id)
        except Exception as exc:
            raise HTTPException(
                status_code=503,
                detail={
                    "error": {
                        "code": "PUBLIC_DATA_UNAVAILABLE",
                        "message": "Bus arrivals are temporarily unavailable.",
                        "detail": {"stopId": normalized_stop_id},
                    }
                },
            ) from exc

        return BusInfoGatewayResult(
            response=self._coerce_response(public_data_response, fallback_stop_id=normalized_stop_id),
            source=self._infer_public_data_source(),
        )

    def save_arrivals(self, response: BusArrivalsResponse) -> None:
        """Store already-normalized arrivals at `/busArrivals/{stopId}`.

        This is a gateway storage interface only. It does not fetch, normalize,
        or enrich provider-specific public data fields.
        """
        payload = response.model_dump(mode="json")
        self.firebase.set(self._firebase_path(response.stopId), payload)

    def _normalize_stop_id(self, stop_id: str) -> str:
        normalized_stop_id = stop_id.strip()
        if not normalized_stop_id:
            raise HTTPException(
                status_code=422,
                detail={
                    "error": {
                        "code": "INVALID_STOP_ID",
                        "message": "stopId must be a non-empty string.",
                        "detail": {"stopId": stop_id},
                    }
                },
            )
        return normalized_stop_id

    def _infer_public_data_source(self) -> BusInfoFallbackSource:
        use_mock = getattr(self.public_data_service, "use_mock", None)
        if isinstance(use_mock, bool):
            return "MOCK" if use_mock else "PUBLIC_API"
        return "PUBLIC_API"

    def _firebase_path(self, stop_id: str) -> str:
        return f"{self.FIREBASE_PATH_PREFIX}/{stop_id}"

    def _coerce_response(self, data: Any, *, fallback_stop_id: str | None = None) -> BusArrivalsResponse:
        if hasattr(data, "model_dump"):
            data = data.model_dump(mode="json")
        if data is None:
            data = {"stopId": fallback_stop_id, "arrivals": []}
        if isinstance(data, list):
            data = {"stopId": fallback_stop_id, "arrivals": data}
        if isinstance(data, dict) and "stopId" not in data and fallback_stop_id:
            data = {**data, "stopId": fallback_stop_id}
        if isinstance(data, dict) and "arrivals" not in data:
            data = {**data, "arrivals": []}
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
