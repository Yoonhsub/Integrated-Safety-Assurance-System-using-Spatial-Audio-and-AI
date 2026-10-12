"""Cloud deployment boundaries; no network, real credentials or cloud writes."""
from dataclasses import replace
import json
from pathlib import Path

import firebase_admin
from firebase_admin import credentials
from fastapi import HTTPException
import pytest

from app.cloud_run import validate_environment
from app.services.firebase_client import FirebaseClient, FirebaseSettings
from scripts import prepare_firebase_deployment as bundle


def settings(**changes):
    return replace(FirebaseSettings("project", "https://project-default-rtdb.firebaseio.com", None,
                                   None, False, True, True), **changes)


def test_adc_initializes_storage_without_key_file(monkeypatch):
    client = FirebaseClient(settings())
    calls = []
    def absent_app():
        raise ValueError("not initialized")
    monkeypatch.setattr(firebase_admin, "get_app", absent_app)
    monkeypatch.setattr(credentials, "ApplicationDefault", lambda: "adc")
    monkeypatch.setattr(firebase_admin, "initialize_app", lambda cred, options: calls.append((cred, options)))
    assert client.initialize()
    assert not client.using_mock
    assert calls == [("adc", {"databaseURL": client.settings.database_url, "projectId": "project"})]


@pytest.mark.parametrize("operation", ["get", "set", "update", "push", "delete"])
def test_production_storage_never_falls_back_to_memory(operation):
    client = FirebaseClient(settings(use_mock_data=True))
    arguments = ("example",) if operation in {"get", "delete"} else ("example", {"value": 1})
    with pytest.raises(HTTPException) as error:
        getattr(client, operation)(*arguments)
    assert error.value.status_code == 503
    assert client._memory_db.get("example") is None


def test_adc_failure_blocks_write(monkeypatch):
    client = FirebaseClient(settings())
    def unavailable():
        raise RuntimeError("credential unavailable")
    monkeypatch.setattr(firebase_admin, "get_app", unavailable)
    with pytest.raises(HTTPException) as error:
        client.set("rideRequests/example", {"status": "WAITING"})
    assert error.value.status_code == 503
    assert client._memory_db.get("rideRequests") is None


def test_production_probe_cannot_report_mock_success():
    with pytest.raises(HTTPException) as error:
        FirebaseClient(settings(use_mock_data=True)).probe()
    assert error.value.status_code == 503


def test_explicit_bad_key_does_not_silently_switch_to_adc(tmp_path):
    assert not settings(service_account_path=tmp_path / "absent.json").credentials_ready


@pytest.fixture
def cloud_environment(monkeypatch):
    values = {"APP_ENV": "staging", "FIREBASE_PROJECT_ID": "project",
              "FIREBASE_DATABASE_URL": "https://project-default-rtdb.firebaseio.com",
              "FIREBASE_USE_ADC": "true", "FIREBASE_USE_MOCK": "false",
              "BACKEND_CORS_ORIGINS": "https://project.web.app"}
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    for key in ("FIREBASE_SERVICE_ACCOUNT_PATH", "FIREBASE_AUTH_EMULATOR_HOST", "FIREBASE_DATABASE_EMULATOR_HOST"):
        monkeypatch.delenv(key, raising=False)


def test_cloud_configuration_accepts_adc(cloud_environment):
    validate_environment()


@pytest.mark.parametrize("name,value", [
    ("APP_ENV", "development"), ("FIREBASE_PROJECT_ID", ""),
    ("FIREBASE_USE_MOCK", "true"), ("FIREBASE_USE_ADC", "false"),
    ("FIREBASE_AUTH_EMULATOR_HOST", "localhost:9099"),
    ("FIREBASE_DATABASE_EMULATOR_HOST", "localhost:9000"),
    ("BACKEND_CORS_ORIGINS", "*"), ("BACKEND_CORS_ORIGINS", "http://localhost:5173"),
    ("FIREBASE_DATABASE_URL", "<copy-url>"),
])
def test_cloud_configuration_rejects_unsafe_values(cloud_environment, monkeypatch, name, value):
    monkeypatch.setenv(name, value)
    with pytest.raises(RuntimeError):
        validate_environment()


def test_backend_bundle_uses_allowlist(tmp_path):
    output = tmp_path / "context"
    bundle.prepare_backend(output)
    assert (output / "backend/api/app/cloud_run.py").is_file()
    assert (output / "services/public_data/examples/mock_bus_arrivals.json").is_file()
    files = [p.relative_to(output).as_posix() for p in output.rglob("*") if p.is_file()]
    assert not any(p.endswith((".zip", ".pt", ".env")) or "secrets/" in p or ".venv/" in p for p in files)
    with pytest.raises(ValueError, match="already exists"):
        bundle.prepare_backend(output)


def test_preparation_cannot_write_into_checkout():
    with pytest.raises(ValueError, match="outside"):
        bundle.reserve_output(bundle.ROOT / "deployment-output")


def test_public_defines_reject_extra_credentials(tmp_path):
    config = {key: "public-value" for key in bundle.DEFINE_KEYS}
    config["MOBI_FIREBASE_PROJECT_ID"] = bundle.PROJECT
    config["private_key"] = "never-copy"
    path = tmp_path / "defines.json"
    path.write_text(json.dumps(config))
    with pytest.raises(ValueError, match="only the five"):
        bundle.load_defines(path)


def test_hosting_deploy_does_not_include_database_rules():
    config = json.loads((bundle.ROOT / "infrastructure/firebase/hosting.config.json").read_text())
    assert set(config) == {"hosting"}
    assert config["hosting"]["public"] == "web"


def test_compile_check_does_not_produce_default_deployment_config(tmp_path):
    for name in ("passenger", "driver"):
        path = tmp_path / "web" / name / "index.html"
        path.parent.mkdir(parents=True)
        path.write_text(f'<base href="/{name}/">')
    bundle.finalize_web(tmp_path, "https://deployment-not-configured.invalid")
    assert not (tmp_path / "firebase.json").exists()
    assert (tmp_path / "firebase.compile-check.json").exists()
    assert json.loads((tmp_path / "build_report.json").read_text())["deployable"] is False


def test_incorrect_web_base_path_blocks_packaging(tmp_path):
    path = tmp_path / "web/passenger/index.html"
    path.parent.mkdir(parents=True)
    path.write_text('<base href="/">')
    with pytest.raises(ValueError, match="base href"):
        bundle.finalize_web(tmp_path, "https://example.run.app")
    assert not (tmp_path / "firebase.json").exists()
