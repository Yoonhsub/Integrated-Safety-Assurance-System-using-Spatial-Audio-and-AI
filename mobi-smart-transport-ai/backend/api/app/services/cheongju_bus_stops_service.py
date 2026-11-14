from __future__ import annotations

import os
import math
import time
from dataclasses import dataclass, replace
from collections import OrderedDict
from threading import Lock
from contextvars import ContextVar
from contextlib import contextmanager
from functools import lru_cache
from datetime import datetime, timezone

import httpx


_DEFAULT_BASE_URL = "https://api.odcloud.kr/api"
_DEFAULT_PATH = "/15041896/v1/uddi:083f11f7-5067-429b-a75d-e32f94269aaf"
_CACHE_ONLY = ContextVar("tago_stop_cache_only", default=False)


def stop_cache_only_active() -> bool:
    return _CACHE_ONLY.get()


@contextmanager
def stop_cache_only():
    token = _CACHE_ONLY.set(True)
    try:
        yield
    finally:
        _CACHE_ONLY.reset(token)


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
    distance_meters: float | None = None
    cache_hit: bool = False


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
            key=lambda item: self._distance_meters(origin_lat, origin_lng, item[3], item[2]),
        )
        return CheongjuBusStopMatch(
            service_id=service_id,
            stop_name=matched_name,
            longitude=longitude,
            latitude=latitude,
            endpoint=self.endpoint,
            fetched_at=fetched_at,
            total_count=total_count,
            distance_meters=self._distance_meters(origin_lat, origin_lng, latitude, longitude),
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

    def search_by_name(self, *, stop_name: str, limit: int = 5) -> list[CheongjuBusStopMatch]:
        """정류소명으로 후보 여러 개를 반환한다.

        같은 이름의 상·하행 정류장이 존재할 수 있으므로, 단일 match 대신 후보 목록을
        보존한다. 방향 판단은 다음 경로 계산 섹션에서 노선 진행 순서로 수행한다.
        """
        if not self._is_enabled():
            return []

        rows, total_count, fetched_at = self._catalog()
        target = self._normalize_name(stop_name)
        parsed_rows = [parsed for row in rows if (parsed := self._parse_row(row)) is not None]
        exact = [item for item in parsed_rows if self._normalize_name(item[1]) == target]
        candidates = exact or [item for item in parsed_rows if target in self._normalize_name(item[1])]
        return [
            CheongjuBusStopMatch(
                service_id=service_id,
                stop_name=matched_name,
                longitude=longitude,
                latitude=latitude,
                endpoint=self.endpoint,
                fetched_at=fetched_at,
                total_count=total_count,
            )
            for service_id, matched_name, longitude, latitude in candidates[: max(1, limit)]
        ]

    def find_nearby(
        self,
        *,
        origin_lat: float,
        origin_lng: float,
        limit: int = 5,
        radius_meters: float = 1000.0,
    ) -> list[CheongjuBusStopMatch]:
        """좌표 주변 정류소 후보를 거리순으로 반환한다."""
        if not self._is_enabled():
            return []

        rows, total_count, fetched_at = self._catalog()
        candidates: list[tuple[float, tuple[str, str, float, float]]] = []
        for row in rows:
            parsed = self._parse_row(row)
            if parsed is None:
                continue
            service_id, stop_name, longitude, latitude = parsed
            distance = self._distance_meters(origin_lat, origin_lng, latitude, longitude)
            if distance <= radius_meters:
                candidates.append((distance, parsed))

        candidates.sort(key=lambda item: item[0])
        return [
            CheongjuBusStopMatch(
                service_id=service_id,
                stop_name=stop_name,
                longitude=longitude,
                latitude=latitude,
                endpoint=self.endpoint,
                fetched_at=fetched_at,
                total_count=total_count,
                distance_meters=distance,
            )
            for distance, (service_id, stop_name, longitude, latitude) in candidates[: max(1, limit)]
        ]

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
    def _distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
        radius = 6371000.0
        phi1 = math.radians(lat1)
        phi2 = math.radians(lat2)
        d_phi = math.radians(lat2 - lat1)
        d_lambda = math.radians(lng2 - lng1)
        a = (
            math.sin(d_phi / 2) ** 2
            + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
        )
        return 2 * radius * math.atan2(math.sqrt(a), math.sqrt(1 - a))


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


class TagoBusStopsService(CheongjuBusStopsService):
    """Bounded TAGO lookup; no ODCloud IDs, seed fallback, or stale cache."""
    requires_public_stops = True
    _base = "https://apis.data.go.kr/1613000/BusSttnInfoInqireService"

    def __init__(self, *, client=None, cache_seconds: float = 60.0):
        super().__init__(client=client, cache_seconds=min(max(cache_seconds, 0.0), 60.0))
        self._owns_client = client is None
        self._queries = OrderedDict()
        self._query_lock = Lock()

    @property
    def dataset_name(self) -> str:
        return "TAGO 버스정류소정보"

    @property
    def endpoint(self) -> str:
        return self._base

    def _query(self, operation: str, params: dict) -> list[CheongjuBusStopMatch]:
        # Exact request identity; never cache credentials, failures or empty results.
        # Nonblocking lock avoids queueing another external lookup behind a slow one.
        if not self._is_enabled():
            return []
        if not os.getenv("PUBLIC_DATA_API_KEY", "").strip():
            raise ValueError("TAGO_STOP_KEY_MISSING")
        identity = (self._base, "33010", operation, tuple(sorted(params.items())))
        if not self._query_lock.acquire(blocking=False):
            raise ValueError("TAGO_STOP_BUSY")
        try:
            now = time.monotonic()
            expired = [k for k, (at, _) in self._queries.items() if now - at >= self._cache_seconds]
            for k in expired:
                del self._queries[k]
            cached = self._queries.get(identity)
            if cached is not None:
                self._queries.move_to_end(identity)
                return [replace(m, cache_hit=True) for m in cached[1]]
            from app.services.vision_binding_service import vision_binding_service
            if _CACHE_ONLY.get() or vision_binding_service.has_camera_reservation():
                raise ValueError("TAGO_STOP_CACHE_NOT_READY")
            rows = self._fetch_query(operation, params)
            if rows and self._cache_seconds > 0:
                self._queries[identity] = (time.monotonic(), tuple(rows))
                while len(self._queries) > 128:
                    self._queries.popitem(last=False)
            return rows
        finally:
            self._query_lock.release()

    def close(self) -> None:
        """Release only an internally owned transport; injected clients belong to callers."""
        with self._query_lock:
            if self._owns_client and self._client is not None:
                self._client.close()
                self._client = None

    def _fetch_query(self, operation: str, params: dict) -> list[CheongjuBusStopMatch]:
        if not self._is_enabled():
            return []
        key = os.getenv("PUBLIC_DATA_API_KEY", "").strip()
        if not key:
            raise ValueError("TAGO_STOP_KEY_MISSING")
        # The key is decoded once; httpx performs the one URL encoding step.
        from urllib.parse import unquote
        params = {**params, "serviceKey": unquote(key), "_type": "json", "pageNo": 1, "numOfRows": 100}
        url = self._base + "/" + operation
        try:
            # Keep connections across cold *query* misses, rather than creating a
            # fresh TCP/TLS connection for each different stop lookup. No retries.
            if self._client is None:
                self._client = httpx.Client(
                    timeout=2.0, follow_redirects=False,
                    limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
                )
            response = self._client.get(url, params=params, timeout=2.0, follow_redirects=False)
            response.raise_for_status()
            payload = response.json()["response"]
            if str(payload["header"]["resultCode"]) not in {"0", "00"}:
                raise ValueError("TAGO_STOP_PROVIDER_REJECTED")
            body = payload["body"]
            total = int(body["totalCount"])
            rows = (body.get("items") or {}).get("item", [])
            if isinstance(rows, dict):
                rows = [rows]
            if not isinstance(rows, list) or total < 0:
                raise ValueError("TAGO_STOP_MALFORMED")
            if total != len(rows) or int(body.get("pageNo", 1)) != 1:
                raise ValueError("TAGO_STOP_INCOMPLETE_PAGE")
            fetched = datetime.now(timezone.utc)
            unique = {}
            for row in rows:
                # Nearby API includes citycode; name lookup is scoped by cityCode.
                city = row.get("citycode")
                if operation == "getCrdntPrxmtSttnList" and city is None:
                    raise ValueError("TAGO_STOP_CITY_MISSING")
                if city is not None and str(city) != "33010":
                    continue
                if not isinstance(row["nodeid"], str) or not isinstance(row["nodenm"], str):
                    raise ValueError("TAGO_STOP_INVALID_ROW")
                node = row["nodeid"].strip()
                name = row["nodenm"].strip()
                lat, lng = float(row["gpslati"]), float(row["gpslong"])
                import re
                if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", node) or not name or not (-90 <= lat <= 90 and -180 <= lng <= 180):
                    raise ValueError("TAGO_STOP_INVALID_ROW")
                match = CheongjuBusStopMatch(node, name, lng, lat, url, fetched, total)
                if node in unique and unique[node] != match:
                    raise ValueError("TAGO_STOP_CONFLICTING_NODE")
                unique[node] = match
            return list(unique.values())
        except httpx.TimeoutException:
            raise ValueError("TAGO_STOP_TIMEOUT") from None
        except httpx.HTTPError:
            raise ValueError("TAGO_STOP_HTTP_ERROR") from None
        except (KeyError, TypeError, AttributeError, OverflowError):
            raise ValueError("TAGO_STOP_MALFORMED") from None
        except ValueError as exc:
            # Never expose JSON parser text, raw body, URL or service key.
            allowed = {"TAGO_STOP_PROVIDER_REJECTED", "TAGO_STOP_MALFORMED", "TAGO_STOP_INCOMPLETE_PAGE", "TAGO_STOP_CITY_MISSING", "TAGO_STOP_INVALID_ROW", "TAGO_STOP_CONFLICTING_NODE"}
            raise ValueError(str(exc) if str(exc) in allowed else "TAGO_STOP_MALFORMED") from None

    def search_by_name(self, *, stop_name: str, limit: int = 5) -> list[CheongjuBusStopMatch]:
        query = stop_name.strip()
        if not query:
            return []
        rows = self._query("getSttnNoList", {"cityCode": "33010", "nodeNm": query})
        target = self._normalize_name(query)
        exact = [m for m in rows if self._normalize_name(m.stop_name) == target]
        matches = exact or [m for m in rows if target in self._normalize_name(m.stop_name)]
        return sorted(matches, key=lambda m: m.service_id)[:max(1, limit)]

    def find_by_name(self, *, stop_name: str) -> CheongjuBusStopMatch | None:
        matches = self.search_by_name(stop_name=stop_name, limit=100)
        return matches[0] if len(matches) == 1 else None

    def find_nearest(self, *, stop_name: str, origin_lat: float, origin_lng: float) -> CheongjuBusStopMatch | None:
        if not (-90 <= origin_lat <= 90 and -180 <= origin_lng <= 180):
            raise ValueError("TAGO_STOP_INVALID_COORDINATES")
        matches = self.search_by_name(stop_name=stop_name, limit=100)
        if not matches:
            return None
        from dataclasses import replace
        matches = sorted((replace(m, distance_meters=self._distance_meters(origin_lat, origin_lng, m.latitude, m.longitude)) for m in matches), key=lambda m: (m.distance_meters, m.service_id))
        if len(matches) > 1 and abs(matches[0].distance_meters - matches[1].distance_meters) < 0.01:
            return None
        return matches[0]

    def find_nearby(self, *, origin_lat: float, origin_lng: float, limit: int = 5, radius_meters: float = 1000.0) -> list[CheongjuBusStopMatch]:
        if not (-90 <= origin_lat <= 90 and -180 <= origin_lng <= 180) or not math.isfinite(radius_meters) or radius_meters < 0:
            raise ValueError("TAGO_STOP_INVALID_COORDINATES")
        from dataclasses import replace
        matches = self._query("getCrdntPrxmtSttnList", {"gpsLati": origin_lat, "gpsLong": origin_lng})
        matches = [replace(m, distance_meters=self._distance_meters(origin_lat, origin_lng, m.latitude, m.longitude)) for m in matches]
        return sorted((m for m in matches if m.distance_meters <= min(radius_meters, 500.0)), key=lambda m: (m.distance_meters, m.service_id))[:max(1, limit)]


def create_bus_stops_service() -> CheongjuBusStopsService:
    provider = os.getenv("CHEONGJU_BUS_STOPS_PROVIDER", "odcloud").strip().lower()
    if provider == "tago":
        return TagoBusStopsService()
    if provider != "odcloud":
        raise ValueError("Unsupported bus-stop provider")
    return CheongjuBusStopsService()


@lru_cache(maxsize=2)
def _shared_bus_stops_service(provider: str) -> CheongjuBusStopsService:
    if provider == "tago":
        return TagoBusStopsService()
    if provider == "odcloud":
        return CheongjuBusStopsService()
    raise ValueError("Unsupported bus-stop provider")


def get_shared_bus_stops_service() -> CheongjuBusStopsService:
    # Provider is deployment configuration, never supplied by the caller.
    return _shared_bus_stops_service(os.getenv("CHEONGJU_BUS_STOPS_PROVIDER", "odcloud").strip().lower())
