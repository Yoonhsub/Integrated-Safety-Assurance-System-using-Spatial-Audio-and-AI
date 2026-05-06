from fastapi.testclient import TestClient
from app.main import app


def test_health():
    client = TestClient(app)
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json()["status"] == "ok"

def test_health_exposes_runtime_mode():
    client = TestClient(app)
    res = client.get("/health")
    assert res.status_code == 200
    body = res.json()
    assert body["service"] == "mobi-backend-api"
    assert body["firebaseMode"] in {"mock", "firebase-admin"}


def test_firebase_client_imports_and_uses_mock_without_credentials():
    from app.services.firebase_client import FirebaseClient

    client = FirebaseClient()
    assert client.initialize() is False
    assert client.using_mock is True

    client.clear_mock_store()
    client.set("/health/check", {"ok": True})
    assert client.get("health/check") == {"ok": True}
    client.update("health/check", {"mode": "mock"})
    assert client.get("/health/check") == {"ok": True, "mode": "mock"}
    key = client.push("events", {"type": "TEST"})
    assert client.get(f"events/{key}") == {"type": "TEST"}
    client.delete("health/check")
    assert client.get("health/check") is None

