from fastapi.testclient import TestClient

from app.main import app


client = TestClient(app)


def test_geofence_rejects_extra_field_and_null_timestamp() -> None:
    base_payload = {
        "userId": "user001",
        "stopId": "stop001",
        "lat": 36.6281,
        "lng": 127.4562,
    }

    extra_response = client.post("/geofence/check", json={**base_payload, "unexpected": "x"})
    assert extra_response.status_code == 422

    null_timestamp_response = client.post("/geofence/check", json={**base_payload, "timestamp": None})
    assert null_timestamp_response.status_code == 422


def test_ride_request_create_rejects_extra_field() -> None:
    response = client.post(
        "/ride-requests",
        json={
            "userId": "user001",
            "stopId": "stop001",
            "routeId": "route502",
            "busNo": "502",
            "unexpected": "x",
        },
    )
    assert response.status_code == 422


def test_ride_request_status_update_rejects_extra_field() -> None:
    response = client.patch(
        "/ride-requests/request001/status",
        json={"status": "ACCEPTED", "unexpected": "x"},
    )
    assert response.status_code == 422


def test_notification_rejects_extra_field() -> None:
    response = client.post(
        "/notifications/send",
        json={
            "targetUserId": "user001",
            "type": "SYSTEM",
            "title": "알림",
            "body": "테스트 알림입니다.",
            "unexpected": "x",
        },
    )
    assert response.status_code == 422

# Section 4 geofence behavior tests
from app.api.routes.geofence import _service
from app.services.firebase_client import get_firebase_client




TEST_GEOFENCE = {
    "safeZone": [
        {"lat": 36.0000, "lng": 127.0000},
        {"lat": 36.0000, "lng": 127.0100},
        {"lat": 36.0100, "lng": 127.0100},
        {"lat": 36.0100, "lng": 127.0000},
    ],
    "warningZones": [
        {
            "name": "테스트 주의 구역",
            "polygon": [
                {"lat": 36.0060, "lng": 127.0060},
                {"lat": 36.0060, "lng": 127.0080},
                {"lat": 36.0080, "lng": 127.0080},
                {"lat": 36.0080, "lng": 127.0060},
            ],
        }
    ],
    "dangerZones": [
        {
            "name": "테스트 위험 구역",
            "polygon": [
                {"lat": 36.0020, "lng": 127.0020},
                {"lat": 36.0020, "lng": 127.0040},
                {"lat": 36.0040, "lng": 127.0040},
                {"lat": 36.0040, "lng": 127.0020},
            ],
        }
    ],
    "updatedAt": "2026-04-18T14:32:00+09:00",
}


def setup_function() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()
    _service.reset_for_tests()
    firebase.set("/geofences/stop-test", TEST_GEOFENCE)


def test_geofence_safe_status_and_location_storage() -> None:
    response = client.post(
        "/geofence/check",
        json={"userId": "user-safe", "stopId": "stop-test", "lat": 36.0050, "lng": 127.0050},
    )

    assert response.status_code == 200
    body = response.json()
    assert body == {
        "status": "SAFE",
        "message": "안전 구역 안에 있습니다.",
        "shouldSpeak": False,
        "shouldVibrate": False,
        "eventId": None,
    }
    stored_location = get_firebase_client().get("/users/user-safe/currentLocation")
    assert stored_location["lat"] == 36.0050
    assert stored_location["lng"] == 127.0050
    assert "updatedAt" in stored_location


def test_geofence_danger_status_creates_transition_event() -> None:
    response = client.post(
        "/geofence/check",
        json={"userId": "user-danger", "stopId": "stop-test", "lat": 36.0030, "lng": 127.0030},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "DANGER"
    assert body["shouldSpeak"] is True
    assert body["shouldVibrate"] is True
    assert body["eventId"]

    event = get_firebase_client().get(f"/systemLogs/{body['eventId']}")
    assert event["type"] == "GEOFENCE_ALERT"
    assert event["relatedUserId"] == "user-danger"
    assert "current=DANGER" in event["message"]


def test_geofence_warning_and_out_of_area_statuses() -> None:
    warning_response = client.post(
        "/geofence/check",
        json={"userId": "user-warning", "stopId": "stop-test", "lat": 36.0070, "lng": 127.0070},
    )
    assert warning_response.status_code == 200
    assert warning_response.json()["status"] == "WARNING"
    assert warning_response.json()["shouldSpeak"] is True
    assert warning_response.json()["shouldVibrate"] is False

    out_response = client.post(
        "/geofence/check",
        json={"userId": "user-out", "stopId": "stop-test", "lat": 36.0200, "lng": 127.0200},
    )
    assert out_response.status_code == 200
    assert out_response.json()["status"] == "OUT_OF_AREA"
    assert out_response.json()["shouldSpeak"] is True
    assert out_response.json()["shouldVibrate"] is True


def test_geofence_unknown_status_when_stop_has_no_geofence_data() -> None:
    response = client.post(
        "/geofence/check",
        json={"userId": "user-unknown", "stopId": "missing-stop", "lat": 36.0050, "lng": 127.0050},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "UNKNOWN"
    assert body["shouldSpeak"] is False
    assert body["shouldVibrate"] is False
    assert body["eventId"] is None
