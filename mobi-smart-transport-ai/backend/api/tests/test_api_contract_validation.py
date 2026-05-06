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
