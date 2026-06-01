from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from app.services.firebase_client import FirebaseClient, get_firebase_client


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# Demo-only paths that this service is allowed to overwrite when reset=True.
# We never wipe the entire database; only these well-known demo nodes.
DEMO_PATHS: tuple[str, ...] = (
    "users/passenger-demo-001",
    "drivers/ride-driver-001",
    "busStops/mock-stop-001",
    "busStops/mock-stop-002",
    "busStops/mock-stop-003",
    "geofences/mock-stop-001",
    "busArrivals/mock-stop-001",
    "fcmTokens/users/passenger-demo-001",
    "v3GuidanceSessions/demo-session",
)


class FirebaseDemoSeedService:
    """Seeds deterministic demo data into the Realtime Database.

    Works against the real Firebase Admin SDK when credentials are available,
    and transparently falls back to the in-memory mock store otherwise. It only
    writes to a fixed set of demo paths and never performs a destructive
    full-database wipe.
    """

    def __init__(self, firebase_client: FirebaseClient | None = None) -> None:
        self._firebase = firebase_client or get_firebase_client()

    def _demo_payload(self) -> dict[str, dict[str, Any]]:
        now = _now()
        return {
            "users/passenger-demo-001": {
                "role": "passenger",
                "displayName": "데모 승객",
                "userType": "visually_impaired",
                "currentLocation": {
                    "lat": 36.6357,
                    "lng": 127.4595,
                    "updatedAt": now,
                },
                "createdAt": now,
                "updatedAt": now,
            },
            "drivers/ride-driver-001": {
                "busNo": "502",
                "routeId": "mock-route-502",
                "currentLocation": {
                    "lat": 36.6361,
                    "lng": 127.4599,
                    "updatedAt": now,
                },
                "status": "ACTIVE",
                "updatedAt": now,
            },
            "busStops/mock-stop-001": {
                "name": "사창사거리 정류장",
                "lat": 36.6357,
                "lng": 127.4595,
                "description": "MOBI V3 데모 기본 정류장",
            },
            "busStops/mock-stop-002": {
                "name": "충북대학교병원 정류장",
                "lat": 36.6245,
                "lng": 127.4612,
                "description": "MOBI V3 데모 목적지 변경용 정류장",
            },
            "busStops/mock-stop-003": {
                "name": "청주고속버스터미널 정류장",
                "lat": 36.6268,
                "lng": 127.4312,
                "description": "MOBI V3 데모 터미널 정류장",
            },
            "geofences/mock-stop-001": {
                "safeZone": [
                    {"lat": 36.63575, "lng": 127.45945},
                    {"lat": 36.63575, "lng": 127.45955},
                    {"lat": 36.63565, "lng": 127.45955},
                    {"lat": 36.63565, "lng": 127.45945},
                ],
                "warningZones": [
                    {
                        "name": "정류장 경계 경고 구역",
                        "polygon": [
                            {"lat": 36.63585, "lng": 127.45935},
                            {"lat": 36.63585, "lng": 127.45965},
                            {"lat": 36.63555, "lng": 127.45965},
                            {"lat": 36.63555, "lng": 127.45935},
                        ],
                    }
                ],
                "dangerZones": [
                    {
                        "name": "차도 위험 구역",
                        "polygon": [
                            {"lat": 36.63595, "lng": 127.45925},
                            {"lat": 36.63595, "lng": 127.45975},
                            {"lat": 36.63545, "lng": 127.45975},
                            {"lat": 36.63545, "lng": 127.45925},
                        ],
                    }
                ],
                "updatedAt": now,
            },
            "busArrivals/mock-stop-001": {
                "stopId": "mock-stop-001",
                "arrivals": [
                    {
                        "routeId": "mock-route-502",
                        "busNo": "502",
                        "arrivalMinutes": 6,
                        "remainingStops": 3,
                        "lowFloor": True,
                        "congestion": "NORMAL",
                        "updatedAt": now,
                    },
                    {
                        "routeId": "mock-route-823",
                        "busNo": "823",
                        "arrivalMinutes": 12,
                        "remainingStops": 6,
                        "lowFloor": False,
                        "congestion": "LOW",
                        "updatedAt": now,
                    },
                ],
            },
            "fcmTokens/users/passenger-demo-001": {
                "token": "demo-web-token",
                "platform": "web",
                "updatedAt": now,
            },
            "v3GuidanceSessions/demo-session": {
                "sessionId": "demo-session",
                "passengerId": "passenger-demo-001",
                "routeId": "mock-route-502",
                "busNo": "502",
                "stopId": "mock-stop-001",
                "status": "WAITING_AT_STOP",
                "currentStep": "APPROACH_STOP",
                "createdAt": now,
                "updatedAt": now,
            },
        }

    def seed(self, *, reset: bool = False) -> dict[str, Any]:
        """Seed demo data and return a result summary.

        Never raises: on any failure it records the error and reports it so the
        API layer can respond without a 500.
        """
        # Ensure initialization is attempted with current settings.
        self._firebase.initialize(force=True)

        payload = self._demo_payload()
        seeded_paths: list[str] = []
        errors: list[str] = []

        for path, value in payload.items():
            try:
                if reset:
                    # Overwrite only this specific demo node.
                    self._firebase.delete(path)
                self._firebase.set(path, value)
                seeded_paths.append("/" + path)
            except Exception as exc:  # pragma: no cover - defensive
                errors.append(f"{path}: {exc}")

        # Append a system log entry (push key) describing the seed action.
        try:
            self._firebase.push(
                "systemLogs",
                {
                    "type": "FIREBASE_DEMO_INIT",
                    "level": "INFO",
                    "message": "Firebase demo database initialized.",
                    "createdAt": _now(),
                },
            )
        except Exception as exc:  # pragma: no cover - defensive
            errors.append(f"systemLogs: {exc}")

        using_mock = self._firebase.using_mock
        mode = "mock" if using_mock else "firebase-admin"
        seeded = len(seeded_paths) > 0 and not errors

        if using_mock:
            message = "서비스 계정이 없어 mock DB에 데모 데이터를 초기화했습니다."
        else:
            message = "Firebase demo database initialized."
        if errors:
            message = f"{message} (일부 경로 실패: {len(errors)}건)"

        return {
            "ok": len(seeded_paths) > 0,
            "mode": mode,
            "initialized": self._firebase.is_initialized,
            "usingMock": using_mock,
            "seeded": seeded,
            "reset": reset,
            "seededPaths": seeded_paths,
            "errors": errors,
            "lastError": self._firebase.last_error,
            "message": message,
        }


def get_firebase_demo_seed_service() -> FirebaseDemoSeedService:
    return FirebaseDemoSeedService()
