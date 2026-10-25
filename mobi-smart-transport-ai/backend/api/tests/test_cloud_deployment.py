"""Cloud deployment boundaries; no network, real credentials or cloud writes."""
from dataclasses import replace
import json
from pathlib import Path
from types import SimpleNamespace

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
    registry = {}
    def absent_app(name='[DEFAULT]'):
        if name not in registry:
            raise ValueError("not initialized")
        return registry[name]
    monkeypatch.setattr(firebase_admin, "get_app", absent_app)
    monkeypatch.setattr(credentials, "ApplicationDefault", lambda: "adc")
    def initialize(cred, options):
        calls.append((cred, options))
        app = SimpleNamespace(name='[DEFAULT]', project_id=options['projectId'], options=options)
        registry[app.name] = app
        return app
    monkeypatch.setattr(firebase_admin, "initialize_app", initialize)
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



@pytest.mark.parametrize('name',['passenger','driver'])
def test_build_uses_app_specific_define_file_and_keeps_single_site_paths(tmp_path,monkeypatch,name):
    from app.cloud_test import MAIN_WEB_APP_IDS
    configs={}
    for app_name in ('passenger','driver'):
        p=tmp_path/f'{app_name}-public.json'
        p.write_text(json.dumps({'MOBI_FIREBASE_API_KEY':'public-test-key',
            'MOBI_FIREBASE_APP_ID':MAIN_WEB_APP_IDS[app_name],
            'MOBI_FIREBASE_MESSAGING_SENDER_ID':'882602390759',
            'MOBI_FIREBASE_PROJECT_ID':bundle.PROJECT,
            'MOBI_FIREBASE_AUTH_DOMAIN':bundle.PROJECT+'.firebaseapp.com'}))
        configs[app_name]=p
    commands=[];output=tmp_path/'prepared-web'
    def run(args,cwd,**kwargs):
        commands.append((args,Path(cwd)))
        if args[1:3]==['build','web']:
            app_name=Path(cwd).name.replace('_app','')
            target=Path(cwd)/'build/web/index.html';target.parent.mkdir(parents=True)
            target.write_text(f'<base href="/{app_name}/">')
    monkeypatch.setattr(bundle.subprocess,'run',run)
    bundle.prepare_web(output,configs['passenger'],configs['driver'],'https://example.invalid','flutter-fixture')
    args,cwd=next((a,c) for a,c in commands if a[1:3]==['build','web'] and c.name==name+'_app')
    assert f'--base-href=/{name}/' in args
    assert f'--dart-define-from-file={output / (name+"-defines.json")}' in args
    data=json.loads((output/f'{name}-defines.json').read_text())
    assert data['MOBI_FIREBASE_APP_ID']==MAIN_WEB_APP_IDS[name]
    assert data['MOBI_API_BASE_URL']=='https://example.invalid'
    hosting=json.loads((output/'firebase.compile-check.json').read_text())
    assert hosting['hosting']['site']=='mobi-smart-transport'


def test_deployment_prepare_rejects_swapped_id_before_build(tmp_path,monkeypatch):
    from app.cloud_test import MAIN_WEB_APP_IDS
    data={'MOBI_FIREBASE_API_KEY':'public-test-key','MOBI_FIREBASE_APP_ID':MAIN_WEB_APP_IDS['driver'],
          'MOBI_FIREBASE_MESSAGING_SENDER_ID':'882602390759','MOBI_FIREBASE_PROJECT_ID':bundle.PROJECT,
          'MOBI_FIREBASE_AUTH_DOMAIN':bundle.PROJECT+'.firebaseapp.com'}
    path=tmp_path/'passenger.json';path.write_text(json.dumps(data))
    with pytest.raises(ValueError,match='mapping'):bundle.load_defines(path,'passenger')


@pytest.mark.parametrize("change", [
    "normal", "cached", "add-other", "replace-before-reference", "delete-before-reference",
    "app-url", "settings-url", "replace-inside-reference", "delete-inside-reference",
    "read-error", "delete-error",
])
def test_probe_pins_target_across_default_app_changes(monkeypatch, change):
    """Exercise the product probe, with SDK/database/credentials replaced locally."""
    from firebase_admin import db
    import os
    for key in list(os.environ):
        if key.startswith('MOBI_CLOUD_TEST'):
            monkeypatch.delenv(key)
    client = FirebaseClient(settings())
    original = SimpleNamespace(name='[DEFAULT]', project_id=client.settings.project_id,
                               options={'databaseURL': client.settings.database_url})
    other = SimpleNamespace(name='[DEFAULT]', project_id='offline-other-project',
                            options={'databaseURL': 'https://offline-other.invalid'})
    registry = {'[DEFAULT]': original}
    def get_app(name='[DEFAULT]'):
        if name not in registry:
            raise ValueError('App was deleted')
        return registry[name]
    monkeypatch.setattr(firebase_admin, 'get_app', get_app)
    monkeypatch.setattr(credentials, 'ApplicationDefault', lambda: pytest.fail('ADC fallback'))
    events = []
    references = []
    class Reference:
        def set(self, value):
            events.append('SET')
            self.value = value
        def get(self):
            events.append('GET')
            if change == 'read-error':
                raise RuntimeError('offline read failed')
            return self.value
        def delete(self):
            events.append('DELETE')
            if change == 'delete-error':
                raise RuntimeError('offline delete failed')
    def reference(path, app=None, url=None):
        if change == 'replace-inside-reference':
            registry['[DEFAULT]'] = other
        if change == 'delete-inside-reference':
            registry.clear()
        # The old implementation resolves the implicit default here. Record it
        # before asserting so a wrong-target attempt is observable before fix.
        selected = app if app is not None else registry.get('[DEFAULT]')
        references.append((selected, url))
        assert app is original and url == client.settings.database_url
        if registry.get(original.name) is not original:
            raise ValueError('Original SDK App is no longer registered')
        assert path == client.PROBE_PATH
        return Reference()
    monkeypatch.setattr(db, 'reference', reference)
    assert client.initialize()
    original_use_memory = client._use_memory
    def checked_then_changed():
        result = original_use_memory()
        if change == 'replace-before-reference':
            registry['[DEFAULT]'] = other
        elif change == 'delete-before-reference':
            registry.clear()
        elif change == 'app-url':
            original.options['databaseURL'] = 'https://offline-other.invalid'
        elif change == 'settings-url':
            client.settings = replace(client.settings, database_url='https://offline-other.invalid')
        return result
    monkeypatch.setattr(client, '_use_memory', checked_then_changed)
    if change == 'add-other':
        registry['other'] = other
    result = client.probe()
    if change in {'normal', 'cached', 'add-other'}:
        assert result['ok'] is True
        assert events == ['SET', 'GET', 'DELETE']
        if change == 'cached':
            assert client.test_connection()['ok'] is True
            assert events == ['SET', 'GET', 'DELETE'] * 2
    else:
        assert result['ok'] is False
        if change not in {'read-error', 'delete-error'}:
            assert events == []
    assert all(app is original and url == client._pinned_target[1] for app, url in references)
    assert not client.using_mock


def test_cloud_test_probe_still_denied_before_any_storage(monkeypatch):
    monkeypatch.setenv('MOBI_CLOUD_TEST', '1')
    client = FirebaseClient(settings())
    monkeypatch.setattr(client, '_use_memory', lambda: pytest.fail('Cloud-test probe reached storage'))
    with pytest.raises(HTTPException) as error:
        client.probe()
    assert error.value.status_code == 403
