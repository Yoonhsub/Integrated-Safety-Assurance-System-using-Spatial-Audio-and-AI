"""Opt-in real HTTP Auth/RTDB Emulator tests; never use ADC or cloud endpoints."""
from contextlib import contextmanager
from pathlib import Path
import os
from uuid import uuid4

import firebase_admin
from firebase_admin import auth, credentials, db
from google.oauth2.credentials import Credentials
import pytest
import requests

from app import cloud_test
from scripts import cloud_test as cli
from scripts.cloud_test_lifecycle import Lifecycle, conditional_delete_rest

pytestmark = pytest.mark.skipif(os.getenv('MOBI_AUTH_RUNNER_EMULATOR_TESTS') != '1',
                                reason='Explicit isolated Auth/RTDB Emulator opt-in required')


@pytest.fixture
def real_run(monkeypatch, tmp_path):
    auth_host, db_host = '127.0.0.1:9199', '127.0.0.1:9100'
    # No arbitrary endpoints accepted. These tests never load ADC.
    assert os.getenv('MOBI_AUTH_RUNNER_AUTH_HOST') == auth_host
    assert os.getenv('MOBI_AUTH_RUNNER_DATABASE_HOST') == db_host
    for key in list(os.environ):
        if key.startswith(('FIREBASE_', 'GOOGLE_', 'MOBI_CLOUD_TEST', 'MOBI_LOCAL_DEMO')) or key in {
                'K_SERVICE', 'GAE_ENV', 'OPENAI_API_KEY', 'GEMINI_API_KEY'}:
            monkeypatch.delenv(key, raising=False)
    project = 'mobi-cloud-test'
    run = 'emu-' + uuid4().hex[:18]
    def web(name):
        return {'MOBI_FIREBASE_API_KEY': 'emulator-public-key', 'MOBI_FIREBASE_APP_ID': '1:123:web:' + ('a'*24 if name=='passenger' else 'b'*24),
                'MOBI_FIREBASE_MESSAGING_SENDER_ID': '123', 'MOBI_FIREBASE_PROJECT_ID': project,
                'MOBI_FIREBASE_AUTH_DOMAIN': project + '.firebaseapp.com'}
    config = {'projectId': project, 'databaseUrl': 'https://mobi-cloud-test-default-rtdb.firebaseio.com/', 'runId': run,
              'mainProjectTest': False, 'backendPort': 8011, 'passengerPort': 5183, 'driverPort': 5184,
              'passenger': web('passenger'), 'driver': web('driver')}
    from test_cloud_test import register_synthetic_project
    register_synthetic_project(monkeypatch,config)
    for key, value in cli.environment_for(config).items():
        monkeypatch.setenv(key, value)

    class EmulatorOnlyCredential(credentials.Base):
        def get_credential(self):
            # Emulator's documented local administrator token, not an Owner ADC.
            return Credentials('owner')

    app = firebase_admin.initialize_app(EmulatorOnlyCredential(), {
        'projectId': 'demo-mobi-local', 'databaseURL': 'https://demo-mobi-local-default-rtdb.firebaseio.com',
        'httpTimeout': 5}, name='auth-runner-' + uuid4().hex)

    @contextmanager
    def emulator_environment():
        with monkeypatch.context() as env:
            env.setenv('FIREBASE_AUTH_EMULATOR_HOST', auth_host)
            env.setenv('FIREBASE_DATABASE_EMULATOR_HOST', db_host)
            yield

    class AuthAdapter:
        pass
    adapter = AuthAdapter()
    touched_users = set()
    for method in ('get_user', 'get_user_by_email', 'create_user', 'set_custom_user_claims', 'delete_user'):
        def call(*args, _method=method, **kwargs):
            with emulator_environment():
                value = getattr(auth, _method)(*args, app=app, **kwargs)
                if _method == 'create_user':
                    touched_users.add(value.uid)
                return value
        setattr(adapter, method, call)

    scope = cloud_test.CloudTestScope(project, config['databaseUrl'], run, False)
    class Storage:
        def get(self, logical):
            with emulator_environment():
                return db.reference(scope.storage_path(logical), app=app).get()
        def transaction(self, logical, transform):
            with emulator_environment():
                return db.reference(scope.storage_path(logical), app=app).transaction(transform)
        def delete_if_unchanged(self, logical, expected):
            with emulator_environment():
                reference = db.reference(scope.storage_path(logical), app=app)
                url = f'http://{db_host}' + scope.storage_path(logical) + '.json?ns=demo-mobi-local-default-rtdb'
                return conditional_delete_rest(reference, url, Credentials('owner'), expected)

    runner = Lifecycle(cli, config, 'emulator-stage-test', tmp_path / 'execution.json',
                       auth_client=adapter, storage=Storage())
    try:
        yield runner, adapter, auth_host, db_host
    finally:
        # Only fixture-created local emulator UIDs. No project-wide clearing.
        for uid in touched_users:
            try:
                adapter.delete_user(uid)
            except auth.UserNotFoundError:
                pass
        firebase_admin.delete_app(app)


def test_real_emulator_accounts_claims_rtdb_direct_denial_and_cleanup(real_run):
    runner, adapter, auth_host, db_host = real_run
    password = 'unique-emulator-only-password-for-auth-test'
    assert runner.run('preflight')['status'] == 'PASS'
    assert runner.run('auth-bootstrap', password)['accounts'] == 4
    assert runner.run('auth-bootstrap', password)['status'] == 'PASS'
    assert runner.run('rtdb-bootstrap')['records'] == 3
    for account in runner.accounts:
        assert adapter.get_user(account['uid']).custom_claims == account['claims']
    account = runner.accounts[0]
    with requests.Session() as client:
        client.trust_env = False
        login = client.post(f'http://{auth_host}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword',
                            params={'key': 'emulator-public-key'},
                            json={'email': account['email'], 'password': password, 'returnSecureToken': True}, timeout=5)
        assert login.status_code == 200
        token = login.json()['idToken']
        profile = runner.scope.storage_path('/drivers/' + runner.scope.uid('driver-502'))
        response = client.get(f'http://{db_host}' + profile + '.json',
                              params={'ns': 'demo-mobi-local-default-rtdb', 'auth': token}, timeout=5)
        assert response.status_code in {401, 403}
    result = runner.run('cleanup')
    assert result['status'] == 'PARTIAL'
    assert all(item['status'] == 'MANUAL_REQUIRED' for item in result['resources'] if item['kind'] == 'auth')
    for account in runner.accounts:
        assert adapter.get_user(account['uid']).custom_claims == account['claims']
    for driver in runner.drivers:
        assert runner.storage.get('/drivers/' + driver) is None
    assert runner.run('cleanup')['status'] == 'PARTIAL'


@pytest.mark.parametrize('collision', ['uid', 'email'])
def test_real_emulator_uid_and_email_collisions_do_not_modify_user(real_run, collision):
    runner, adapter, _, _ = real_run
    account = runner.accounts[-1]
    uid = account['uid'] if collision == 'uid' else 'existing-' + uuid4().hex
    email = account['email'] if collision == 'email' else 'existing-' + uuid4().hex + '@example.test'
    adapter.create_user(uid=uid, email=email, password='unrelated-emulator-fixture-password', display_name='Existing fixture')
    with pytest.raises(ValueError):
        runner.run('auth-bootstrap', 'unique-emulator-only-password-for-auth-test')
    assert adapter.get_user(uid).display_name == 'Existing fixture'
    assert not runner.journal.data['accounts']


def test_real_emulator_partial_create_is_recorded_and_cleaned(real_run):
    runner, adapter, _, _ = real_run
    def fail_claims(*args, **kwargs):
        raise RuntimeError('deliberate local fixture failure')
    adapter.set_custom_user_claims = fail_claims
    with pytest.raises(RuntimeError):
        runner.run('auth-bootstrap', 'unique-emulator-only-password-for-auth-test')
    assert len(runner.journal.data['accounts']) == 1
    assert runner.run('cleanup')['status'] == 'PARTIAL'



def test_real_emulator_forged_session_journal_cannot_delete(real_run):
    runner, _, _, _ = real_run
    logical = '/v3GuidanceSessions/v3-' + uuid4().hex
    value = {'sessionId': logical.rsplit('/', 1)[1], 'state': 'UNRELATED_FIXTURE'}
    runner.storage.transaction(logical, lambda raw: value)
    try:
        with runner.journal.locked():
            runner.journal.data['records'][logical] = {
                'state': 'verified', 'expected': value, 'physicalPath': runner.scope.storage_path(logical),
                'creationProof': {'verified': True}}
            runner.journal.save()
        result = runner.run('cleanup')
        assert result['status'] == 'PARTIAL'
        assert runner.storage.get(logical) == value
    finally:
        # Separate local fixture teardown, never product cleanup authority.
        runner.storage.delete_if_unchanged(logical, value)


def test_real_emulator_etag_change_prevents_delete(real_run, monkeypatch):
    runner, _, _, _ = real_run
    runner.run('auth-bootstrap', 'unique-emulator-only-password-for-auth-test')
    runner.run('rtdb-bootstrap')
    logical = '/drivers/' + runner.scope.uid('driver-502')
    changed = {'concurrentLocalFixture': True}
    original = requests.Session.delete
    calls = []
    def race(session, url, **kwargs):
        if not calls:
            runner.storage.transaction(logical, lambda raw: changed)
        calls.append(url)
        return original(session, url, **kwargs)
    monkeypatch.setattr(requests.Session, 'delete', race)
    try:
        result = runner.run('cleanup')
        assert result['status'] == 'PARTIAL'
        assert runner.storage.get(logical) == changed
        assert any(item['status'] == 'FAILED' and item['kind'] == 'rtdb' for item in result['resources'])
    finally:
        monkeypatch.setattr(requests.Session, 'delete', original)
        runner.storage.delete_if_unchanged(logical, changed)
