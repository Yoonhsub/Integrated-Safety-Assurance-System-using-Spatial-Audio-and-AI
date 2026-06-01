from __future__ import annotations

import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone

import httpx


_DEFAULT_BASE_URL = "https://api.odcloud.kr/api"
_DEFAULT_PATH = "/15041896/v1/uddi:083f11f7-5067-429b-a75d-e32f94269aaf"
_DATASET_NAME = "충청북도_청주시_버스정보시스템_정류소_20250401"


@dataclass(frozen=True)
class CheongjuBusStopMatch:
    service_id: str
    stop_name: str
    longitude: float
    latitude: float
    endpoint: str
    fetched_at: datetime
    total_count: int


class CheongjuBusStopsService:
    """Fetch and search the approved Cheongju bus-stop catalog from odcloud."""

    def __init__(
        self,
        *,
        client: httpx.Client | None = None,
        cache_seconds: float = 600.0,
    ) -> None:
        self._client = client
        self._cache_seconds = cache_seconds
        self._cached_rows: list[dict] | None = None
        self._cached_total_count = 0
        self._cached_at_monotonic = 0.0
        self._cached_at_utc: datetime | None = None

    @property
    def dataset_name(self) -> str:
        return _DATASET_NAME

    @property
    def endpoint(self) -> str:
        base_url = (os.getenv("CHEONGJU_BUS_STOPS_BASE_URL") or _DEFAULT_BASE_URL).rstrip("/")
        path = os.getenv("CHEONGJU_BUS_STOPS_PATH") or _DEFAULT_PATH
        return f"{base_url}/{path.lstrip('/')}"

    def find_nearest(
        self,
        *,
        stop_name: str,
        origin_lat: float,
        origin_lng: float,
    ) -> CheongjuBusStopMatch | None:
        if not self._is_enabled():
            return None

        rows, total_count, fetched_at = self._catalog()
        target = self._normalize_name(stop_name)
        candidates = [
            parsed
            for row in rows
            if (parsed := self._parse_row(row)) is not None
            and self._normalize_name(parsed[1]) == target
        ]
        if not candidates:
            candidates = [
                parsed
                for row in rows
                if (parsed := self._parse_row(row)) is not None
                and target in self._normalize_name(parsed[1])
            ]
        if not candidates:
            return None

        service_id, matched_name, longitude, latitude = min(
            candidates,
            key=lambda item: (item[2] - origin_lng) ** 2 + (item[3] - origin_lat) ** 2,
        )
        return CheongjuBusStopMatch(
            service_id=service_id,
            stop_name=matched_name,
            longitude=longitude,
            latitude=latitude,
            endpoint=self.endpoint,
            fetched_at=fetched_at,
            total_count=total_count,
        )

    def find_by_name(self, *, stop_name: str) -> CheongjuBusStopMatch | None:
        """좌표 없이 정류소명만으로 승인된 카탈로그에서 정류소를 조회한다.

        웹에서 위치 권한이 없어 origin 좌표가 없을 때, 정류소 위치 증빙 카드가
        0,0/0건으로 비지 않도록 거리 정렬 대신 이름 일치(정확→포함)로 매칭한다.
        """
        if not self._is_enabled():
            return None

        rows, total_count, fetched_at = self._catalog()
        target = self._normalize_name(stop_name)
        candidates = [
            parsed
            for row in rows
            if (parsed := self._parse_row(row)) is not None
            and self._normalize_name(parsed[1]) == target
        ]
        if not candidates:
            candidates = [
                parsed
                for row in rows
                if (parsed := self._parse_row(row)) is not None
                and target in self._normalize_name(parsed[1])
            ]
        if not candidates:
            return None

        service_id, matched_name, longitude, latitude = candidates[0]
        return CheongjuBusStopMatch(
            service_id=service_id,
            stop_name=matched_name,
            longitude=longitude,
            latitude=latitude,
            endpoint=self.endpoint,
            fetched_at=fetched_at,
            total_count=total_count,
        )

    def _catalog(self) -> tuple[list[dict], int, datetime]:
        now = time.monotonic()
        if (
            self._cached_rows is not None
            and self._cached_at_utc is not None
            and now - self._cached_at_monotonic < self._cache_seconds
        ):
            return self._cached_rows, self._cached_total_count, self._cached_at_utc

        api_key = os.getenv("PUBLIC_DATA_API_KEY", "").strip()
        if not api_key:
            raise ValueError("PUBLIC_DATA_API_KEY is not configured")

        get = self._client.get if self._client is not None else httpx.get
        response = get(
            self.endpoint,
            params={
                "serviceKey": api_key,
                "page": "1",
                "perPage": "5000",
            },
            headers={"Accept": "application/json"},
            timeout=10.0,
        )
        response.raise_for_status()
        payload = response.json()
        rows = payload.get("data")
        if not isinstance(rows, list):
            raise ValueError("Cheongju bus-stop API returned an invalid payload")

        fetched_at = datetime.now(timezone.utc)
        self._cached_rows = [row for row in rows if isinstance(row, dict)]
        self._cached_total_count = int(payload.get("totalCount") or len(self._cached_rows))
        self._cached_at_monotonic = now
        self._cached_at_utc = fetched_at
        return self._cached_rows, self._cached_total_count, fetched_at

    @staticmethod
    def _is_enabled() -> bool:
        value = os.getenv("CHEONGJU_BUS_STOPS_ENABLED", "false")
        return value.strip().lower() in {"true", "1", "yes", "on"}

    @staticmethod
    def _normalize_name(value: str) -> str:
        return "".join(value.replace("정류장", "").split()).lower()

    @staticmethod
    def _parse_row(row: dict) -> tuple[str, str, float, float] | None:
        try:
            return (
                str(row["서비스ID"]),
                str(row["정류소명"]),
                float(row["좌표(X)"]),
                float(row["좌표(Y)"]),
            )
        except (KeyError, TypeError, ValueError):
            return None
