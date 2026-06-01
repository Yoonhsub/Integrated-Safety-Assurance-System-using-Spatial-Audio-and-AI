from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

import httpx


_DIRECT_PATH = "/v1/api/searchPubTransPathT"


class OdsayUnavailableError(RuntimeError):
    """Raised when ODsay cannot provide candidates and local fallback should run."""


@dataclass(frozen=True)
class OdsayTransitResult:
    raw_response: dict[str, Any]


class OdsayClient:
    """Backend-only client for the ODsay public-transit route API."""

    def __init__(self, *, client: httpx.Client | None = None) -> None:
        self._client = client or httpx.Client(timeout=_timeout_seconds())

    @staticmethod
    def is_enabled() -> bool:
        return _env_bool("ODSAY_ENABLED", default=False)

    def search_public_transit_path(
        self,
        *,
        origin_lat: float,
        origin_lng: float,
        destination_lat: float,
        destination_lng: float,
    ) -> OdsayTransitResult:
        """Search routes with ODsay coordinates in the required X=lng, Y=lat order."""
        if not self.is_enabled():
            raise OdsayUnavailableError("ODsay is disabled.")

        use_gateway = _env_bool("ODSAY_USE_GATEWAY", default=False)
        url = _gateway_url() if use_gateway else _direct_url()
        api_key = os.getenv("ODSAY_API_KEY", "").strip()
        if not use_gateway and not api_key:
            raise OdsayUnavailableError("ODsay API key is not configured.")

        params: dict[str, str | int | float] = {
            "SX": origin_lng,
            "SY": origin_lat,
            "EX": destination_lng,
            "EY": destination_lat,
            "SearchType": 0,
            "SearchPathType": 2,
            "output": "json",
        }
        if not use_gateway:
            params["apiKey"] = api_key

        try:
            response = self._client.get(url, params=params, headers=_gateway_headers() if use_gateway else None)
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise OdsayUnavailableError(f"ODsay request failed: {type(exc).__name__}") from exc

        if not isinstance(payload, dict):
            raise OdsayUnavailableError("ODsay returned an invalid response.")
        if payload.get("error"):
            raise OdsayUnavailableError(f"ODsay returned an error: {_error_summary(payload['error'])}")
        if not isinstance(payload.get("result"), dict):
            raise OdsayUnavailableError("ODsay response did not include a result object.")
        return OdsayTransitResult(raw_response=payload)


def _direct_url() -> str:
    return f"{(os.getenv('ODSAY_BASE_URL') or 'https://api.odsay.com').rstrip('/')}{_DIRECT_PATH}"


def _gateway_url() -> str:
    value = os.getenv("ODSAY_GATEWAY_URL", "").strip()
    if not value:
        raise OdsayUnavailableError("ODsay gateway URL is not configured.")
    return value


def _gateway_headers() -> dict[str, str] | None:
    token = os.getenv("ODSAY_GATEWAY_TOKEN", "").strip()
    return {"Authorization": f"Bearer {token}"} if token else None


def _timeout_seconds() -> float:
    try:
        return max(0.1, float(os.getenv("ODSAY_TIMEOUT_SECONDS", "8.0")))
    except ValueError:
        return 8.0


def _env_bool(name: str, *, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"true", "1", "yes", "on"}


def _error_summary(value: Any) -> str:
    if isinstance(value, list) and value:
        value = value[0]
    if isinstance(value, dict):
        code = str(value.get("code") or "unknown")
        message = str(value.get("message") or value.get("msg") or "unknown error")
        return f"{code}: {message}"
    return "unknown error"
