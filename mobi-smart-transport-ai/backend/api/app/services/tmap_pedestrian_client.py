"""TMAP 보행자 경로안내 저수준 클라이언트.

- API key는 환경변수 TMAP_API_KEY에서만 읽고 header `appKey`로 전달한다.
- 요청/응답을 로깅하지 않으며 key를 절대 노출하지 않는다.
- 응답(GeoJSON FeatureCollection)에서 거리/시간/polyline/안내문구만 추출한다.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field

import httpx

_DEFAULT_BASE_URL = "https://apis.openapi.sk.com/tmap/routes/pedestrian"


@dataclass(frozen=True)
class TmapWalkingResult:
    total_distance_meters: float | None
    total_time_seconds: int | None
    polyline: list[tuple[float, float]] = field(default_factory=list)  # (lat, lng)
    instructions: list[dict] = field(default_factory=list)


def is_enabled() -> bool:
    return os.getenv("TMAP_PEDESTRIAN_ENABLED", "false").strip().lower() in {"true", "1", "yes", "on"}


def _base_url() -> str:
    return (os.getenv("TMAP_PEDESTRIAN_BASE_URL") or _DEFAULT_BASE_URL).rstrip("/")


def _timeout_seconds() -> float:
    try:
        return max(1.0, float(os.getenv("TMAP_PEDESTRIAN_TIMEOUT_SECONDS", "5")))
    except ValueError:
        return 5.0


def fetch_pedestrian_route(
    *,
    start_lat: float,
    start_lng: float,
    end_lat: float,
    end_lng: float,
    start_name: str = "현위치",
    end_name: str = "정류장",
    client: httpx.Client | None = None,
) -> TmapWalkingResult | None:
    """TMAP 보행자 경로를 조회한다. 비활성/미설정/실패 시 None을 반환한다(호출자가 fallback)."""
    api_key = os.getenv("TMAP_API_KEY", "").strip()
    if not is_enabled() or not api_key:
        return None

    payload = {
        "startX": f"{start_lng:.7f}",
        "startY": f"{start_lat:.7f}",
        "endX": f"{end_lng:.7f}",
        "endY": f"{end_lat:.7f}",
        "reqCoordType": "WGS84GEO",
        "resCoordType": "WGS84GEO",
        "startName": (start_name or "현위치")[:50],
        "endName": (end_name or "정류장")[:50],
    }
    url = f"{_base_url()}?version=1"
    timeout = _timeout_seconds()
    last_exc: Exception | None = None
    for _attempt in range(2):  # 1 retry
        try:
            poster = client.post if client is not None else httpx.post
            response = poster(
                url,
                headers={"appKey": api_key, "Content-Type": "application/json"},
                json=payload,
                timeout=timeout,
            )
            response.raise_for_status()
            return _parse(response.json())
        except (httpx.HTTPError, ValueError, KeyError) as exc:  # pragma: no cover - network
            last_exc = exc
            continue
    if last_exc is not None:
        return None
    return None


def _parse(body: dict) -> TmapWalkingResult | None:
    features = body.get("features")
    if not isinstance(features, list) or not features:
        return None

    total_distance: float | None = None
    total_time: int | None = None
    polyline: list[tuple[float, float]] = []
    instructions: list[dict] = []

    for feature in features:
        if not isinstance(feature, dict):
            continue
        props = feature.get("properties") or {}
        geometry = feature.get("geometry") or {}
        if total_distance is None and props.get("totalDistance") is not None:
            try:
                total_distance = float(props["totalDistance"])
            except (TypeError, ValueError):
                pass
        if total_time is None and props.get("totalTime") is not None:
            try:
                total_time = int(float(props["totalTime"]))
            except (TypeError, ValueError):
                pass

        gtype = geometry.get("type")
        coords = geometry.get("coordinates")
        if gtype == "Point" and isinstance(coords, list) and len(coords) >= 2:
            polyline.append((float(coords[1]), float(coords[0])))
        elif gtype == "LineString" and isinstance(coords, list):
            for pair in coords:
                if isinstance(pair, list) and len(pair) >= 2:
                    polyline.append((float(pair[1]), float(pair[0])))

        description = props.get("description")
        if isinstance(description, str) and description.strip():
            instruction = {"text": description.strip()}
            if props.get("distance") is not None:
                try:
                    instruction["distanceMeters"] = float(props["distance"])
                except (TypeError, ValueError):
                    pass
            if props.get("time") is not None:
                try:
                    instruction["durationSeconds"] = int(float(props["time"]))
                except (TypeError, ValueError):
                    pass
            instructions.append(instruction)

    # 좌표 중복 제거(연속 동일점)
    deduped: list[tuple[float, float]] = []
    for point in polyline:
        if not deduped or deduped[-1] != point:
            deduped.append(point)

    return TmapWalkingResult(
        total_distance_meters=total_distance,
        total_time_seconds=total_time,
        polyline=deduped,
        instructions=instructions[:20],
    )
