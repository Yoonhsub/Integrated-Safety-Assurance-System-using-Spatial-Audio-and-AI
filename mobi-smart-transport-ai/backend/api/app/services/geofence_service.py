from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from math import asin, cos, radians, sin, sqrt
from typing import Any

from app.schemas.geofence import GeofenceCheckRequest, GeofenceCheckResponse, GeofenceStatus
from app.services.firebase_client import FirebaseClient, get_firebase_client


@dataclass(frozen=True)
class GeoPoint:
    lat: float
    lng: float


@dataclass(frozen=True)
class ZoneHit:
    status: GeofenceStatus
    zone_name: str | None = None


MOCK_GEOFENCES: dict[str, dict[str, Any]] = {
    "stop001": {
        "safeZone": [
            {"lat": 36.6278, "lng": 127.4558},
            {"lat": 36.6278, "lng": 127.4568},
            {"lat": 36.6288, "lng": 127.4568},
            {"lat": 36.6288, "lng": 127.4558},
        ],
        "warningZones": [
            {
                "name": "정류장 경계 주의 구역",
                "polygon": [
                    {"lat": 36.6286, "lng": 127.4565},
                    {"lat": 36.6286, "lng": 127.4569},
                    {"lat": 36.6290, "lng": 127.4569},
                    {"lat": 36.6290, "lng": 127.4565},
                ],
            }
        ],
        "dangerZones": [
            {
                "name": "차도 방향",
                "polygon": [
                    {"lat": 36.6282, "lng": 127.4560},
                    {"lat": 36.6282, "lng": 127.4563},
                    {"lat": 36.6285, "lng": 127.4563},
                    {"lat": 36.6285, "lng": 127.4560},
                ],
            }
        ],
        "updatedAt": "2026-04-18T14:32:00+09:00",
    }
}


class GeofenceService:
    """Geofence evaluator for the section-4 backend skeleton.

    The service intentionally keeps precise map data replaceable. It reads
    `/geofences/{stopId}` from Firebase RTDB when present and falls back to a
    small deterministic mock fixture for local tests/demo. It does not send FCM
    notifications; section 6 wires notification delivery.
    """

    def __init__(self, firebase_client: FirebaseClient | None = None) -> None:
        self.firebase = firebase_client or get_firebase_client()
        self._last_status_by_user_stop: dict[tuple[str, str], GeofenceStatus] = {}

    def check(self, payload: GeofenceCheckRequest) -> GeofenceCheckResponse:
        evaluated_at = payload.timestamp or datetime.now(UTC)
        point = GeoPoint(lat=payload.lat, lng=payload.lng)

        self._store_current_location(payload, evaluated_at)
        geofence = self._load_geofence(payload.stopId)
        if not geofence:
            return self._finalize_result(
                payload=payload,
                status=GeofenceStatus.UNKNOWN,
                message="정류장 지오펜스 데이터가 아직 등록되지 않았습니다.",
                should_speak=False,
                should_vibrate=False,
                evaluated_at=evaluated_at,
                zone_name=None,
            )

        hit = self._evaluate(point, geofence)
        message = self._message_for(hit)
        should_alert = hit.status in {GeofenceStatus.WARNING, GeofenceStatus.DANGER, GeofenceStatus.OUT_OF_AREA}

        return self._finalize_result(
            payload=payload,
            status=hit.status,
            message=message,
            should_speak=should_alert,
            should_vibrate=hit.status in {GeofenceStatus.DANGER, GeofenceStatus.OUT_OF_AREA},
            evaluated_at=evaluated_at,
            zone_name=hit.zone_name,
        )

    def reset_for_tests(self) -> None:
        self._last_status_by_user_stop.clear()

    def _load_geofence(self, stop_id: str) -> dict[str, Any] | None:
        stored = self.firebase.get(f"/geofences/{stop_id}")
        if isinstance(stored, dict):
            return stored
        return MOCK_GEOFENCES.get(stop_id)

    def _store_current_location(self, payload: GeofenceCheckRequest, evaluated_at: datetime) -> None:
        self.firebase.set(
            f"/users/{payload.userId}/currentLocation",
            {
                "lat": payload.lat,
                "lng": payload.lng,
                "updatedAt": evaluated_at.isoformat(),
            },
        )

    def _evaluate(self, point: GeoPoint, geofence: dict[str, Any]) -> ZoneHit:
        for zone in geofence.get("dangerZones") or []:
            if self._point_in_zone(point, zone.get("polygon") or []):
                return ZoneHit(status=GeofenceStatus.DANGER, zone_name=zone.get("name"))

        for zone in geofence.get("warningZones") or []:
            if self._point_in_zone(point, zone.get("polygon") or []):
                return ZoneHit(status=GeofenceStatus.WARNING, zone_name=zone.get("name"))

        safe_zone = geofence.get("safeZone") or []
        if safe_zone:
            if self._point_in_zone(point, safe_zone):
                return ZoneHit(status=GeofenceStatus.SAFE, zone_name="safeZone")
            return ZoneHit(status=GeofenceStatus.OUT_OF_AREA, zone_name="safeZone")

        return ZoneHit(status=GeofenceStatus.UNKNOWN, zone_name=None)

    def _finalize_result(
        self,
        *,
        payload: GeofenceCheckRequest,
        status: GeofenceStatus,
        message: str,
        should_speak: bool,
        should_vibrate: bool,
        evaluated_at: datetime,
        zone_name: str | None,
    ) -> GeofenceCheckResponse:
        key = (payload.userId, payload.stopId)
        previous_status = self._last_status_by_user_stop.get(key)
        self._last_status_by_user_stop[key] = status

        event_id = None
        if self._should_create_event(previous_status, status):
            event_id = self._create_transition_event(
                user_id=payload.userId,
                stop_id=payload.stopId,
                previous_status=previous_status,
                status=status,
                zone_name=zone_name,
                evaluated_at=evaluated_at,
            )

        return GeofenceCheckResponse(
            status=status,
            message=message,
            shouldSpeak=should_speak,
            shouldVibrate=should_vibrate,
            eventId=event_id,
        )

    @staticmethod
    def _should_create_event(previous_status: GeofenceStatus | None, status: GeofenceStatus) -> bool:
        if previous_status != status and previous_status is not None:
            return True
        return status in {GeofenceStatus.WARNING, GeofenceStatus.DANGER, GeofenceStatus.OUT_OF_AREA}

    def _create_transition_event(
        self,
        *,
        user_id: str,
        stop_id: str,
        previous_status: GeofenceStatus | None,
        status: GeofenceStatus,
        zone_name: str | None,
        evaluated_at: datetime,
    ) -> str:
        previous = previous_status.value if previous_status else "NONE"
        message = (
            f"GEOFENCE_STATUS_TRANSITION userId={user_id} stopId={stop_id} "
            f"previous={previous} current={status.value} zone={zone_name or 'unknown'}"
        )
        return self.firebase.push(
            "/systemLogs",
            {
                "type": "GEOFENCE_ALERT",
                "level": "WARNING" if status == GeofenceStatus.WARNING else "INFO",
                "message": message,
                "relatedUserId": user_id,
                "relatedRequestId": None,
                "createdAt": evaluated_at.isoformat(),
            },
        )

    @staticmethod
    def _message_for(hit: ZoneHit) -> str:
        if hit.status == GeofenceStatus.SAFE:
            return "안전 구역 안에 있습니다."
        if hit.status == GeofenceStatus.WARNING:
            return f"주의 구역에 접근 중입니다.{_zone_suffix(hit.zone_name)}"
        if hit.status == GeofenceStatus.DANGER:
            return f"위험 구역에 접근 중입니다. 뒤로 물러나세요.{_zone_suffix(hit.zone_name)}"
        if hit.status == GeofenceStatus.OUT_OF_AREA:
            return "정류장 안전 구역을 벗어났습니다. 지정된 대기 위치로 이동해 주세요."
        return "현재 위치의 안전 상태를 판단할 수 없습니다."

    @classmethod
    def _point_in_zone(cls, point: GeoPoint, polygon_data: list[dict[str, Any]]) -> bool:
        polygon = cls._parse_polygon(polygon_data)
        if len(polygon) >= 3:
            return cls._point_in_polygon(point, polygon)
        if polygon:
            return min(cls._distance_meters(point, vertex) for vertex in polygon) <= 20.0
        return False

    @staticmethod
    def _parse_polygon(polygon_data: list[dict[str, Any]]) -> list[GeoPoint]:
        points: list[GeoPoint] = []
        for raw in polygon_data:
            try:
                points.append(GeoPoint(lat=float(raw["lat"]), lng=float(raw["lng"])))
            except (KeyError, TypeError, ValueError):
                continue
        return points

    @staticmethod
    def _point_in_polygon(point: GeoPoint, polygon: list[GeoPoint]) -> bool:
        inside = False
        j = len(polygon) - 1
        for i, current in enumerate(polygon):
            previous = polygon[j]
            crosses = (current.lng > point.lng) != (previous.lng > point.lng)
            if crosses:
                slope_lat = (previous.lat - current.lat) * (point.lng - current.lng) / (
                    previous.lng - current.lng
                ) + current.lat
                if point.lat < slope_lat:
                    inside = not inside
            j = i
        return inside

    @staticmethod
    def _distance_meters(a: GeoPoint, b: GeoPoint) -> float:
        earth_radius_m = 6_371_000
        lat1 = radians(a.lat)
        lat2 = radians(b.lat)
        delta_lat = radians(b.lat - a.lat)
        delta_lng = radians(b.lng - a.lng)
        hav = sin(delta_lat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(delta_lng / 2) ** 2
        return 2 * earth_radius_m * asin(sqrt(hav))


def _zone_suffix(zone_name: str | None) -> str:
    return f" ({zone_name})" if zone_name else ""
