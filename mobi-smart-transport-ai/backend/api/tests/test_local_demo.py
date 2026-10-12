"""Local emulator isolation and synthetic dispatch, without network access."""
import pytest
from fastapi import HTTPException

from app.local_emulator import EmulatorCredential, validate_local_emulators
from app.security import Principal, current_principal
from app.schemas.ride_request import RideRequestCreate
from app.services.firebase_client import FirebaseClient, FirebaseSettings, load_firebase_settings
from app.services.ride_request_service import RideRequestService


@pytest.fixture
def local_environment(monkeypatch):
    expected = {
        "APP_ENV": "local-demo", "MOBI_LOCAL_DEMO": "1", "FIREBASE_PROJECT_ID": "demo-mobi-local",
        "GOOGLE_CLOUD_PROJECT": "demo-mobi-local", "FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:9099",
        "FIREBASE_DATABASE_EMULATOR_HOST": "127.0.0.1:9000",
        "FIREBASE_DATABASE_URL": "https://demo-mobi-local-default-rtdb.firebaseio.com", "FIREBASE_USE_MOCK": "false",
        "K_SERVICE": "", "GAE_ENV": "", "FIREBASE_SERVICE_ACCOUNT_PATH": "", "GOOGLE_APPLICATION_CREDENTIALS": "",
    }
    for key, value in expected.items(): monkeypatch.setenv(key, value)


def test_explicit_local_emulator_configuration(local_environment):
    validate_local_emulators()
    assert EmulatorCredential().get_credential().valid
    settings = load_firebase_settings()
    assert settings.use_emulator and settings.require_real_storage and settings.credentials_ready
    assert not settings.use_mock_data


@pytest.mark.parametrize("key,value", [
    ("APP_ENV", "production"), ("APP_ENV", "staging"), ("APP_ENV", "development"),
    ("MOBI_LOCAL_DEMO", "0"), ("FIREBASE_PROJECT_ID", "mobi-smart-transport"),
    ("FIREBASE_AUTH_EMULATOR_HOST", "remote.example:9099"),
    ("FIREBASE_DATABASE_EMULATOR_HOST", ""), ("FIREBASE_DATABASE_URL", "https://real.firebaseio.com"),
    ("FIREBASE_USE_MOCK", "true"), ("K_SERVICE", "cloud-service"),
    ("GOOGLE_APPLICATION_CREDENTIALS", "real-key.json"), ("GOOGLE_CLOUD_PROJECT", "real-project"),
])
def test_mixed_or_production_emulator_config_rejected(local_environment, monkeypatch, key, value):
    monkeypatch.setenv(key, value)
    with pytest.raises(ValueError): validate_local_emulators()


def test_local_storage_never_falls_back_to_memory(local_environment, monkeypatch):
    client = FirebaseClient()
    monkeypatch.setattr(client, "initialize", lambda: False)
    with pytest.raises(HTTPException) as error: client.get("/anything")
    assert error.value.status_code == 503


def test_dispatch_uses_server_mapping_only_in_local_demo(local_environment):
    storage = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    storage.set('/localDemoAssignments/MOCK-502', {'busNo': '502', 'driverId': 'synthetic-driver'})
    storage.set('/drivers/synthetic-driver', {'busNo': '502', 'routeId': 'MOCK-502'})
    marker = current_principal.set(Principal('passenger', 'passenger'))
    try:
        service = RideRequestService(storage)
        record = service.create(RideRequestCreate(userId='passenger', stopId='mock-stop-001', routeId='MOCK-502', busNo='502'))
        assert record.targetDriverId == 'synthetic-driver'
        with pytest.raises(HTTPException) as error:
            service.create(RideRequestCreate(userId='passenger', stopId='mock-stop-001', routeId='unknown', busNo='502'))
        assert error.value.status_code == 409
    finally: current_principal.reset(marker)


def test_regular_mode_does_not_synthesize_driver(monkeypatch):
    for key in ('MOBI_LOCAL_DEMO', 'FIREBASE_AUTH_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST'):
        monkeypatch.delenv(key, raising=False)
    storage = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    storage.set('/localDemoAssignments/MOCK-502', {'busNo': '502', 'driverId': 'synthetic-driver'})
    marker = current_principal.set(Principal('passenger', 'passenger'))
    try:
        record = RideRequestService(storage).create(RideRequestCreate(
            userId='passenger', stopId='mock-stop-001', routeId='MOCK-502', busNo='502'))
        assert record.targetDriverId is None
    finally: current_principal.reset(marker)
