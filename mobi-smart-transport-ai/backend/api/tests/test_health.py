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


def test_data_mode_selection_does_not_mutate_process_wide_default(monkeypatch):
    monkeypatch.setenv("PUBLIC_DATA_USE_MOCK", "true")
    client = TestClient(app)

    response = client.post("/config/data-mode", json={"mode": "live"})

    assert response.status_code == 200
    assert response.json() == {"status": "success", "mode": "live"}
    assert client.get("/health").json()["dataMode"] == "mock"


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


def test_firebase_use_mock_overrides_legacy_mock_env(monkeypatch):
    from app.services.firebase_client import load_firebase_settings

    monkeypatch.setenv("USE_MOCK_DATA", "false")
    monkeypatch.setenv("FIREBASE_USE_MOCK", "true")

    settings = load_firebase_settings()

    assert settings.use_mock_data is True
    assert settings.runtime_mode == "mock"


def test_fcm_use_mock_can_force_mock_transport(monkeypatch):
    from app.services.fcm_service import FcmService

    class FakeFirebase:
        using_mock = False

    service = FcmService(firebase_client=FakeFirebase())
    monkeypatch.setenv("FCM_ENABLED", "true")
    monkeypatch.setenv("FCM_USE_MOCK", "true")

    assert service._should_use_mock_transport() is True

    monkeypatch.setenv("FCM_USE_MOCK", "false")

    assert service._should_use_mock_transport() is False
