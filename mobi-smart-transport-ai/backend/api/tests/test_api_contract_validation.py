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


def test_notification_requires_exactly_one_target() -> None:
    multiple_targets_response = client.post(
        "/notifications/send",
        json={
            "targetUserId": "user001",
            "targetDriverId": "driver001",
            "type": "SYSTEM",
            "title": "알림",
            "body": "테스트 알림입니다.",
        },
    )
    assert multiple_targets_response.status_code == 422

    missing_target_response = client.post(
        "/notifications/send",
        json={
            "type": "SYSTEM",
            "title": "알림",
            "body": "테스트 알림입니다.",
        },
    )
    assert missing_target_response.status_code == 422


def test_notification_data_payload_rejects_non_string_values() -> None:
    response = client.post(
        "/notifications/send",
        json={
            "targetUserId": "user001",
            "type": "SYSTEM",
            "title": "알림",
            "body": "테스트 알림입니다.",
            "data": {"stopId": 123},
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
    assert event["level"] == "ERROR"
    assert event["relatedUserId"] == "user-danger"
    assert "current=DANGER" in event["message"]


def test_geofence_does_not_duplicate_event_for_unchanged_alert_status() -> None:
    first_response = client.post(
        "/geofence/check",
        json={"userId": "user-repeat", "stopId": "stop-test", "lat": 36.0030, "lng": 127.0030},
    )
    second_response = client.post(
        "/geofence/check",
        json={"userId": "user-repeat", "stopId": "stop-test", "lat": 36.0030, "lng": 127.0030},
    )

    assert first_response.status_code == 200
    assert second_response.status_code == 200
    assert first_response.json()["status"] == "DANGER"
    assert first_response.json()["eventId"]
    assert second_response.json()["status"] == "DANGER"
    assert second_response.json()["eventId"] is None

    system_logs = get_firebase_client().get("/systemLogs")
    assert isinstance(system_logs, dict)
    assert len(system_logs) == 1


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

# Section 6 FCM notification behavior tests
from app.api.routes.notifications import _service as notification_service
from app.services.fcm_service import FcmOwnerType


def test_notification_send_returns_missing_token_when_target_has_no_fcm_record() -> None:
    get_firebase_client().clear_mock_store()

    response = client.post(
        "/notifications/send",
        json={
            "targetUserId": "user-without-token",
            "type": "SAFETY_ALERT",
            "title": "안전 경고",
            "body": "테스트 알림입니다.",
            "data": {"stopId": "stop-test"},
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["accepted"] is False
    assert body["messageId"] is None
    assert "/fcmTokens/users/user-without-token" in body["detail"]


def test_notification_send_uses_official_user_token_path_and_mock_transport() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()
    notification_service.save_token(
        owner_type=FcmOwnerType.USER,
        owner_id="user-token",
        token="test-user-fcm-token",
        platform="android",
    )

    response = client.post(
        "/notifications/send",
        json={
            "targetUserId": "user-token",
            "type": "SAFETY_ALERT",
            "title": "안전 경고",
            "body": "위험 구역에 접근 중입니다.",
            "data": {"stopId": "stop-test", "geofenceStatus": "DANGER"},
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["accepted"] is True
    assert body["messageId"].startswith("mock-fcm-users-user-token-")
    assert "Mock FCM send accepted" in body["detail"]
    assert firebase.get("/fcmTokens/users/user-token")["token"] == "test-user-fcm-token"
    assert firebase.get("/users/user-token/fcmToken") is None


def test_notification_send_uses_official_driver_token_path_and_mock_transport() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()
    notification_service.save_token(
        owner_type=FcmOwnerType.DRIVER,
        owner_id="driver-token",
        token="test-driver-fcm-token",
        platform="web",
    )

    response = client.post(
        "/notifications/send",
        json={
            "targetDriverId": "driver-token",
            "type": "RIDE_REQUEST",
            "title": "탑승 요청",
            "body": "502번 버스 탑승 요청이 도착했습니다.",
            "data": {"requestId": "request001", "busNo": "502"},
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["accepted"] is True
    assert body["messageId"].startswith("mock-fcm-drivers-driver-token-")
    assert firebase.get("/fcmTokens/drivers/driver-token")["platform"] == "web"
    assert firebase.get("/drivers/driver-token/fcmToken") is None


def test_fcm_service_helper_methods_create_standard_notification_payloads() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()
    notification_service.save_token(
        owner_type=FcmOwnerType.USER,
        owner_id="helper-user",
        token="helper-user-token",
    )
    notification_service.save_token(
        owner_type=FcmOwnerType.DRIVER,
        owner_id="helper-driver",
        token="helper-driver-token",
    )

    safety_result = notification_service.send_safety_alert(
        user_id="helper-user",
        stop_id="stop-test",
        geofence_status="DANGER",
    )
    ride_result = notification_service.send_ride_request_notification(
        driver_id="helper-driver",
        request_id="request-helper",
        user_id="helper-user",
        stop_id="stop-test",
        route_id="route502",
        bus_no="502",
    )

    assert safety_result.accepted is True
    assert safety_result.messageId and safety_result.messageId.startswith("mock-fcm-users-helper-user-")
    assert ride_result.accepted is True
    assert ride_result.messageId and ride_result.messageId.startswith("mock-fcm-drivers-helper-driver-")

# Section 8 rideRequests behavior tests


def test_ride_request_create_persists_without_duplicate_request_id() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()

    response = client.post(
        "/ride-requests",
        json={
            "userId": "ride-user-001",
            "stopId": "stop-test",
            "routeId": "route502",
            "busNo": "502",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["requestId"].startswith("ride-")
    assert body["status"] == "WAITING"
    assert body["updatedAt"] is None

    stored = firebase.get(f"/rideRequests/{body['requestId']}")
    assert stored["userId"] == "ride-user-001"
    assert stored["targetDriverId"] is None
    assert "requestId" not in stored


def test_ride_request_create_notifies_driver_when_token_exists() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()
    notification_service.save_token(
        owner_type=FcmOwnerType.DRIVER,
        owner_id="ride-driver-001",
        token="ride-driver-token",
        platform="android",
    )

    response = client.post(
        "/ride-requests",
        json={
            "userId": "ride-user-002",
            "stopId": "stop-test",
            "routeId": "route502",
            "busNo": "502",
            "targetDriverId": "ride-driver-001",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["targetDriverId"] == "ride-driver-001"
    assert body["status"] == "NOTIFIED"
    assert body["updatedAt"] is not None

    stored = firebase.get(f"/rideRequests/{body['requestId']}")
    assert stored["status"] == "NOTIFIED"
    assert "requestId" not in stored

    list_response = client.get("/drivers/ride-driver-001/ride-requests")
    assert list_response.status_code == 200
    list_body = list_response.json()
    assert list_body["driverId"] == "ride-driver-001"
    assert [item["requestId"] for item in list_body["requests"]] == [body["requestId"]]


def test_ride_request_create_keeps_waiting_when_driver_notification_fails() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()

    response = client.post(
        "/ride-requests",
        json={
            "userId": "ride-user-003",
            "stopId": "stop-test",
            "routeId": "route502",
            "busNo": "502",
            "targetDriverId": "driver-without-token",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "WAITING"
    assert body["targetDriverId"] == "driver-without-token"
    assert firebase.get(f"/rideRequests/{body['requestId']}")["status"] == "WAITING"


def test_ride_request_read_and_status_update_use_firebase_record() -> None:
    firebase = get_firebase_client()
    firebase.clear_mock_store()

    create_response = client.post(
        "/ride-requests",
        json={
            "userId": "ride-user-004",
            "stopId": "stop-test",
            "routeId": "route502",
            "busNo": "502",
        },
    )
    request_id = create_response.json()["requestId"]

    read_response = client.get(f"/ride-requests/{request_id}")
    assert read_response.status_code == 200
    assert read_response.json()["requestId"] == request_id
    assert read_response.json()["status"] == "WAITING"

    update_response = client.patch(f"/ride-requests/{request_id}/status", json={"status": "ACCEPTED"})
    assert update_response.status_code == 200
    update_body = update_response.json()
    assert update_body["status"] == "ACCEPTED"
    assert update_body["updatedAt"] is not None

    stored = firebase.get(f"/rideRequests/{request_id}")
    assert stored["status"] == "ACCEPTED"
    assert "requestId" not in stored


def test_ride_request_get_unknown_request_returns_404() -> None:
    get_firebase_client().clear_mock_store()

    response = client.get("/ride-requests/missing-request")

    assert response.status_code == 404
