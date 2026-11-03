"""Ownership and failure tests. These use explicit in-memory doubles, not Firebase."""
from copy import deepcopy
import json
import os
from types import SimpleNamespace

from firebase_admin.auth import UserNotFoundError
import pytest

from app import cloud_test
from app.services.firebase_client import InMemoryRealtimeDatabase
from scripts import cloud_test as cli
from scripts.cloud_test_lifecycle import Lifecycle, Journal, canonical, conditional_delete_rest

PASSWORD = 'unique-local-test-password-not-a-cloud-credential'


class FakeAuth:
    def __init__(self):
        self.users = {}
        self.created = []
        self.claim_updates = []
        self.deleted = []
        self.fail_claims = False

    def get_user(self, uid):
        if uid not in self.users:
            raise UserNotFoundError('absent')
        return self.users[uid]

    def get_user_by_email(self, email):
        for user in self.users.values():
            if user.email == email:
                return user
        raise UserNotFoundError('absent')

    def create_user(self, **value):
        if value['uid'] in self.users or any(u.email == value['email'] for u in self.users.values()):
            raise RuntimeError('collision')
        user = SimpleNamespace(uid=value['uid'], email=value['email'], display_name=value['display_name'],
                               custom_claims=None, disabled=False,
                               user_metadata=SimpleNamespace(creation_timestamp=123456))
        self.users[user.uid] = user
        self.created.append(user.uid)
        return user

    def set_custom_user_claims(self, uid, claims):
        if self.fail_claims:
            raise RuntimeError('private-provider-error')
        self.users[uid].custom_claims = deepcopy(claims)
        self.claim_updates.append(uid)

    def delete_user(self, uid):
        del self.users[uid]
        self.deleted.append(uid)


@pytest.fixture
def setup_run(monkeypatch, tmp_path):
    for key in list(os.environ):
        if key.startswith(('MOBI_CLOUD_TEST', 'FIREBASE_', 'GOOGLE_', 'MOBI_LOCAL_DEMO')) or key in {
                'K_SERVICE', 'GAE_ENV', 'OPENAI_API_KEY', 'GEMINI_API_KEY'}:
            monkeypatch.delenv(key, raising=False)
    project = 'mobi-cloud-test'
    def web(name):
        return {'MOBI_FIREBASE_API_KEY': 'public-offline-key', 'MOBI_FIREBASE_APP_ID': '1:123:web:' + ('a'*24 if name=='passenger' else 'b'*24),
                'MOBI_FIREBASE_MESSAGING_SENDER_ID': '123', 'MOBI_FIREBASE_PROJECT_ID': project,
                'MOBI_FIREBASE_AUTH_DOMAIN': project + '.firebaseapp.com'}
    config = {'projectId': project, 'databaseUrl': 'https://mobi-cloud-test-default-rtdb.firebaseio.com/', 'runId': 'auth-20261021-a',
              'mainProjectTest': False, 'backendPort': 8011, 'passengerPort': 5183, 'driverPort': 5184,
              'passenger': web('passenger'), 'driver': web('driver')}
    # configure() intentionally sets process environment in the real CLI. Track
    # every key here so a unit test cannot leak staging into unrelated tests.
    from test_cloud_test import register_synthetic_project
    register_synthetic_project(monkeypatch,config)
    for key, value in cli.environment_for(config).items():
        monkeypatch.setenv(key, value)
    auth, db = FakeAuth(), InMemoryRealtimeDatabase()
    runner = Lifecycle(cli, config, 'auth-smoke-a', tmp_path / 'execution.json', auth_client=auth, storage=db)
    return runner, auth, db


def test_new_four_accounts_and_read_only_duplicate_stage(setup_run):
    runner, auth, _ = setup_run
    assert runner.run('auth-bootstrap', PASSWORD)['accounts'] == 4
    assert runner.run('auth-bootstrap', PASSWORD)['status'] == 'PASS'
    assert len(auth.created) == len(auth.claim_updates) == 4
    assert {u.custom_claims['mobi_role'] for u in auth.users.values()} == {'passenger', 'driver'}
    assert PASSWORD not in runner.journal.path.read_text()


@pytest.mark.parametrize('collision', ['uid', 'email'])
def test_all_collisions_checked_before_first_create(setup_run, collision):
    runner, auth, _ = setup_run
    candidate = runner.accounts[-1]
    uid = candidate['uid'] if collision == 'uid' else 'unrelated-google-user'
    email = 'private-existing@example.invalid' if collision == 'uid' else candidate['email']
    auth.users[uid] = SimpleNamespace(uid=uid, email=email, display_name='existing Google account',
                                     custom_claims={'mobi_role': 'admin'}, disabled=False)
    with pytest.raises(ValueError):
        runner.run('auth-bootstrap', PASSWORD)
    assert not auth.created and not auth.claim_updates and not auth.deleted


@pytest.mark.parametrize('field,value', [('uid', 'other'), ('email', 'other@example.test'),
                                        ('claims', {'mobi_role': 'admin'}),
                                        ('claims', {'mobi_role': 'vision_producer'})])
def test_injected_identity_plan_refused_before_sdk(setup_run, monkeypatch, field, value):
    runner, auth, db = setup_run
    original = cli.fixture
    def injected(config):
        accounts, drivers, manifest = original(config)
        accounts[0][field] = value
        return accounts, drivers, manifest
    monkeypatch.setattr(cli, 'fixture', injected)
    with pytest.raises(ValueError):
        Lifecycle(cli, runner.config, runner.case_id, runner.journal.path, auth_client=auth, storage=db)


def test_existing_claims_never_overwritten(setup_run):
    runner, auth, _ = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    auth.users[runner.accounts[0]['uid']].custom_claims['mobi_role'] = 'admin'
    with pytest.raises(ValueError):
        runner.run('auth-bootstrap', PASSWORD)
    assert len(auth.claim_updates) == 4


def test_partial_claim_failure_cleanup(setup_run):
    runner, auth, _ = setup_run
    auth.fail_claims = True
    with pytest.raises(RuntimeError):
        runner.run('auth-bootstrap', PASSWORD)
    saved = json.loads(runner.journal.path.read_text())
    assert len(saved['accounts']) == 1
    assert list(saved['accounts'].values())[0]['state'] == 'created'
    assert 'private-provider-error' not in runner.journal.path.read_text()
    # A retry cannot claim-provision an account which already exists.
    with pytest.raises(ValueError):
        runner.run('auth-bootstrap', PASSWORD)
    assert runner.run('cleanup')['status'] == 'PARTIAL'
    assert auth.users and not auth.deleted
    assert runner.run('cleanup')['status'] == 'PARTIAL'
    with pytest.raises(ValueError):
        runner.run('auth-bootstrap', PASSWORD)


def test_no_adoption_without_original_journal(setup_run, tmp_path):
    runner, auth, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    other = Lifecycle(cli, runner.config, runner.case_id, tmp_path / 'other.json', auth_client=auth, storage=db)
    with pytest.raises(ValueError):
        other.run('auth-bootstrap', PASSWORD)
    assert len(auth.claim_updates) == 4


def test_changed_user_is_not_deleted_and_other_cleanup_continues(setup_run):
    runner, auth, _ = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    uid = runner.accounts[0]['uid']
    auth.users[uid].display_name = 'unrelated owner'
    result = runner.run('cleanup')
    assert result['status'] == 'PARTIAL'
    assert uid in auth.users and not auth.deleted
    assert any(r['target'] == uid and r['status'] == 'MANUAL_REQUIRED' for r in result['resources'])


def test_create_and_cleanup_exact_leaf_records(setup_run):
    runner, auth, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    runner.run('rtdb-bootstrap')
    foreign = '/drivers/unrelated'
    db.set(foreign, {'keep': True})
    assert runner.run('rtdb-bootstrap')['status'] == 'PASS'
    result = runner.run('cleanup')
    assert result['status'] == 'PARTIAL' and len(result['resources']) == 7
    assert db.get(foreign) == {'keep': True}
    assert auth.users and not auth.deleted


def test_completed_rtdb_bootstrap_retry_does_not_write_again(setup_run, monkeypatch):
    runner, _, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    original = db.transaction
    calls = []
    def counted(path, transform):
        calls.append(path)
        return original(path, transform)
    monkeypatch.setattr(db, 'transaction', counted)
    runner.run('rtdb-bootstrap')
    runner.run('rtdb-bootstrap')
    assert len(calls) == 3


def test_existing_rtdb_record_never_overwritten(setup_run):
    runner, _, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    logical = '/drivers/' + runner.scope.uid('driver-502')
    db.set(logical, {'existing': True})
    with pytest.raises(ValueError):
        runner.run('rtdb-bootstrap')
    assert db.get(logical) == {'existing': True}
    assert not json.loads(runner.journal.path.read_text())['records']


def test_changed_record_is_not_deleted(setup_run):
    runner, _, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    runner.run('rtdb-bootstrap')
    logical = '/drivers/' + runner.scope.uid('driver-502')
    db.set(logical, {'foreign': True})
    assert runner.run('cleanup')['status'] == 'PARTIAL'
    assert db.get(logical) == {'foreign': True}


@pytest.mark.parametrize('path', ['/', '/cloudTestRuns', '/ride-requests/x', '/drivers/foreign',
                                 '/v3GuidanceSessions/../foreign', '/rideRequests/foreign'])
def test_cleanup_rejects_invalid_journal_path_before_deletes(setup_run, path):
    runner, auth, _ = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    data = json.loads(runner.journal.path.read_text())
    data['records'][path] = {'expected': {}, 'state': 'verified', 'physicalPath': path}
    runner.journal.path.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        runner.run('cleanup')
    assert not auth.deleted


def test_cleanup_rejects_foreign_uid_before_deletes(setup_run):
    runner, auth, _ = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    data = json.loads(runner.journal.path.read_text())
    data['accounts']['personal-google-uid'] = {'account': {'uid': 'personal-google-uid'}}
    runner.journal.path.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        runner.run('cleanup')
    assert not auth.deleted


def test_cleanup_never_deletes_run_parent_even_with_legacy_mapping(setup_run):
    runner, auth, db = setup_run
    runner.scope = cloud_test.CloudTestScope(runner.scope.project_id, runner.scope.database_url,
                                            runner.scope.run_id, False)
    parent = runner.scope.path
    db.set(parent, {'unrelatedChild': 'keep'})
    with runner.journal.locked():
        runner.journal.data['records'][parent] = {
            'expected': {'unrelatedChild': 'keep'}, 'state': 'verified', 'physicalPath': parent}
        runner.journal.save()
    with pytest.raises(ValueError, match='physical path'):
        runner.run('cleanup')
    assert db.get(parent) == {'unrelatedChild': 'keep'}
    assert not auth.deleted


def test_session_http_success_is_not_persistence_proof(setup_run):
    runner, _, db = setup_run
    sid = 'v3-' + 'a' * 32
    logical = '/v3GuidanceSessions/' + sid
    with runner.journal.locked():
        runner.backend_intent(logical)
        with pytest.raises(ValueError, match='did not persist'):
            runner.record_backend_result(logical, {'sessionId': sid, 'state': 'IDLE'})
        db.set(logical, {'sessionId': sid, 'state': 'IDLE'})
        runner.record_backend_result(logical, {'sessionId': sid, 'state': 'IDLE'})
        assert runner.journal.data['records'][logical]['state'] == 'verified'


def test_session_response_loss_remains_unconfirmed(setup_run):
    runner, _, _ = setup_run
    with runner.journal.locked():
        runner.journal.data['pendingSession'] = True
        runner.journal.save()
    assert runner.run('cleanup')['status'] == 'FAILED'


def test_actual_session_http_200_with_swallowed_storage_failure_is_not_pass(setup_run, monkeypatch):
    from fastapi.testclient import TestClient
    from app.main import app
    from app.security import get_principal, Principal
    from app.services import firebase_client
    runner, _, _ = setup_run
    class BrokenStorage:
        def set(self, *args):
            raise RuntimeError('deliberate local storage failure')
    monkeypatch.setattr(firebase_client, 'get_firebase_client', lambda: BrokenStorage())
    previous = dict(app.dependency_overrides)
    app.dependency_overrides[get_principal] = lambda: Principal(runner.accounts[0]['uid'], 'passenger')
    try:
        with TestClient(app) as client:
            response = client.post('/guidance/session', json={'wakeWord': '紐⑤퉬'})
        assert response.status_code == 200  # Actual product store intentionally swallows persistence errors.
        logical = '/v3GuidanceSessions/' + response.json()['sessionId']
        with runner.journal.locked():
            runner.backend_intent(logical)
            with pytest.raises(ValueError, match='did not persist'):
                runner.record_backend_result(logical, response.json())
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(previous)


def test_auth_cleanup_remains_manual_even_when_delete_method_would_fail(setup_run, monkeypatch):
    runner, auth, _ = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    original = auth.delete_user
    def failed(uid):
        raise RuntimeError('deliberate delete failure')
    monkeypatch.setattr(auth, 'delete_user', failed)
    assert runner.run('cleanup')['status'] == 'PARTIAL'
    assert len(auth.users) == 4 and not auth.deleted
    monkeypatch.setattr(auth, 'delete_user', original)
    assert runner.run('cleanup')['status'] == 'PARTIAL'


def test_unacknowledged_auth_creation_remains_manual_despite_marker(setup_run, monkeypatch):
    runner, auth, _ = setup_run
    original = auth.create_user
    def lost(**kwargs):
        original(**kwargs)
        raise TimeoutError('simulated lost create response')
    monkeypatch.setattr(auth, 'create_user', lost)
    with pytest.raises(TimeoutError):
        runner.run('auth-bootstrap', PASSWORD)
    assert len(auth.users) == 1
    assert list(runner.journal.data['accounts'].values())[0]['state'] == 'intent'
    assert runner.run('cleanup')['status'] == 'PARTIAL'


def test_rtdb_partial_write_failure_is_recorded_and_cleaned(setup_run, monkeypatch):
    runner, _, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    original = db.transaction
    calls = []
    def failed_second(path, transform):
        calls.append(path)
        if len(calls) == 2:
            raise RuntimeError('second write failed')
        return original(path, transform)
    monkeypatch.setattr(db, 'transaction', failed_second)
    with pytest.raises(RuntimeError):
        runner.run('rtdb-bootstrap')
    assert len(runner.journal.data['records']) == 2
    monkeypatch.setattr(db, 'transaction', original)
    assert runner.run('cleanup')['status'] == 'PARTIAL'


def test_lock_prevents_concurrent_stages(setup_run):
    runner, auth, _ = setup_run
    with runner.journal.locked():
        with pytest.raises(ValueError, match='lock'):
            runner.run('auth-bootstrap', PASSWORD)
    assert not auth.created


def test_flutter_stage_does_not_claim_browser_success(setup_run):
    runner, _, _ = setup_run
    assert runner.run('flutter-smoke')['status'] == 'NOT_VERIFIED'


def test_plan_identifies_actual_rtdb_record_path_and_claims(setup_run):
    runner, _, _ = setup_run
    plan = cli.execution_plan(runner.config, runner.case_id)
    assert plan['directRtdbProbePath'] == runner.scope.storage_path('/rideRequests/' + plan['requestId'])
    assert len(plan['accounts']) == 4 and len(plan['planSha256']) == 64


def test_apply_requires_exact_stage_hash_before_sdk(setup_run, tmp_path, monkeypatch, capsys):
    runner, _, _ = setup_run
    config_path = tmp_path / 'public.json'
    config_path.write_text(json.dumps(runner.config))
    monkeypatch.setattr(cli, 'validate_stage_credential', lambda *args: pytest.fail('Credential access before approval'))
    args = ['auth-bootstrap', '--config', str(config_path), '--case-id', runner.case_id,
            '--apply', '--approved-project-id', runner.config['projectId'],
            '--approved-run-id', runner.config['runId'], '--allow-main-project-test']
    assert cli.main(args) == 1
    assert 'stage and plan hash' in capsys.readouterr().err


@pytest.mark.parametrize('kind', ['authorized_user', 'service_account', 'impersonated_service_account'])
def test_wrong_adc_identity_refused_offline(setup_run, tmp_path, monkeypatch, kind):
    runner, _, _ = setup_run
    path = tmp_path / 'fake-adc.json'
    path.write_text(json.dumps({'type': kind, 'service_account_impersonation_url':
        'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/other@example.invalid:generateAccessToken'}))
    monkeypatch.setenv('GOOGLE_APPLICATION_CREDENTIALS', str(path))
    with pytest.raises(ValueError):
        cli.validate_stage_credential('auth-bootstrap', runner.config)


@pytest.mark.parametrize('status,body,changed', [(200, None, False), (412, None, False),
                                               (200, {'unexpected': True}, False),
                                               (200, None, True)])
def test_real_cleanup_transport_uses_etag_and_does_not_retry(monkeypatch, status, body, changed):
    import requests
    calls = []
    expected = {'owned': 'local-fixture'}
    reference = SimpleNamespace(get=lambda **kwargs: ({'foreign': True} if changed else expected, '"etag-a"'))
    class Credential:
        def before_request(self, transport, method, url, headers):
            headers['Authorization'] = 'Bearer local-test-fixture'
    class Session:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def close(self): pass
        def mount(self, *args): pass
        def delete(self, url, **kwargs):
            calls.append((url, kwargs))
            return SimpleNamespace(status_code=status, json=lambda: body)
    monkeypatch.setattr(requests, 'Session', Session)
    if status == 200 and body is None and not changed:
        conditional_delete_rest(reference, 'https://offline.invalid/approved.json', Credential(), expected)
    else:
        with pytest.raises(ValueError):
            conditional_delete_rest(reference, 'https://offline.invalid/approved.json', Credential(), expected)
    assert len(calls) == (0 if changed else 1)
    if calls:
        assert calls[0][1]['headers']['If-Match'] == '"etag-a"'
        assert calls[0][1]['allow_redirects'] is False


# HIGH review attacks: these assertions fail against the previous implementation.
def test_high_inserted_session_is_not_cleanup_authority(setup_run):
    runner, auth, db = setup_run
    logical = '/v3GuidanceSessions/v3-' + 'b' * 32
    value = {'sessionId': 'v3-' + 'b' * 32, 'state': 'EXISTING'}
    db.set(logical, value)
    with runner.journal.locked():
        runner.journal.data['records'][logical] = {
            'expected': value, 'state': 'verified', 'physicalPath': runner.scope.storage_path(logical),
            'creationProof': {'verified': True, 'executionId': runner.journal.data['executionId']}}
        runner.journal.save()
    result = runner.run('cleanup')
    assert db.get(logical) == value
    assert result['status'] in {'PARTIAL', 'FAILED'}


def test_high_forged_initial_record_is_not_cleanup_authority(setup_run):
    runner, _, db = setup_run
    with runner.journal.locked():
        logical = '/drivers/' + runner.scope.uid('driver-502')
        value = runner.initial_records()[logical]
        db.set(logical, value)
        runner.journal.data['records'][logical] = {
            'expected': value, 'state': 'verified', 'physicalPath': runner.scope.storage_path(logical)}
        runner.journal.save()
    result = runner.run('cleanup')
    assert db.get(logical) == value
    assert result['status'] in {'PARTIAL', 'FAILED'}


def test_high_auth_automatic_delete_is_disabled_even_for_owned_account(setup_run):
    runner, auth, _ = setup_run
    # Use an already existing owned account without provisioning a new cloud user.
    with runner.journal.locked():
        account = runner.accounts[0]
        user = auth.create_user(uid=account['uid'], email=account['email'], display_name=runner.marker)
        runner.journal.data['accounts'][account['uid']] = {
            'account': account, 'state': 'created', 'createdAt': user.user_metadata.creation_timestamp}
        runner.journal.save()
    result = runner.run('cleanup')
    assert account['uid'] in auth.users
    assert auth.deleted == []
    assert result['status'] in {'PARTIAL', 'FAILED'}


def test_high_main_claims_provisioning_fails_before_any_auth_access(setup_run, monkeypatch):
    runner, auth, _ = setup_run
    runner.scope = cloud_test.CloudTestScope(cloud_test.MAIN_PROJECT_ID, cloud_test.MAIN_DATABASE_URL, runner.scope.run_id, True)
    def unexpected(*args):
        pytest.fail('Main-project provisioning must be blocked before lookup/mutation')
    monkeypatch.setattr(auth, 'get_user', unexpected)
    with pytest.raises(ValueError, match='atomic'):
        runner.run('auth-bootstrap', PASSWORD)
    assert not auth.created and not auth.claim_updates



def test_high_delete_toctou_path_never_reaches_auth_lookup_or_delete(setup_run, monkeypatch):
    runner, auth, _ = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    original = auth.get_user
    victim = runner.accounts[0]['uid']
    raced = []
    def replace_after_lookup(uid):
        old = original(uid)
        if uid == victim:
            auth.users[uid] = SimpleNamespace(uid=uid, email='replacement@example.invalid',
                display_name='Replacement owner', custom_claims={'mobi_role': 'admin'}, disabled=False,
                user_metadata=SimpleNamespace(creation_timestamp=999999))
            raced.append(uid)
        return old
    monkeypatch.setattr(auth, 'get_user', replace_after_lookup)
    assert runner.run('cleanup')['status'] == 'PARTIAL'
    assert not raced and not auth.deleted and victim in auth.users


def test_claims_replacement_detected_before_write(setup_run, monkeypatch):
    runner, auth, _ = setup_run
    original = auth.create_user
    def replace_before_lookup(**kwargs):
        created = original(**kwargs)
        auth.users[created.uid] = SimpleNamespace(uid=created.uid, email='replacement@example.invalid',
            display_name='Replacement owner', custom_claims={'mobi_role': 'admin'}, disabled=False,
            user_metadata=SimpleNamespace(creation_timestamp=999999))
        return created
    monkeypatch.setattr(auth, 'create_user', replace_before_lookup)
    with pytest.raises(ValueError, match='changed before provisioning'):
        runner.run('auth-bootstrap', PASSWORD)
    assert not auth.claim_updates and len(auth.users) == 1
    assert runner.run('cleanup')['status'] == 'PARTIAL'
    assert not auth.deleted


def test_dedicated_project_final_claims_race_is_detected_only_after_mutation(setup_run, monkeypatch):
    # This deliberately demonstrates the residual Auth API limitation. It is
    # NOT an assertion of atomicity or approval to run it in the main project.
    runner, auth, _ = setup_run
    original = auth.set_custom_user_claims
    victims = []
    def replace_at_api_boundary(uid, claims):
        auth.users[uid] = SimpleNamespace(uid=uid, email='replacement@example.invalid',
            display_name='Replacement owner', custom_claims={'mobi_role': 'admin'}, disabled=False,
            user_metadata=SimpleNamespace(creation_timestamp=999999))
        victims.append(uid)
        original(uid, claims)
    monkeypatch.setattr(auth, 'set_custom_user_claims', replace_at_api_boundary)
    with pytest.raises(ValueError, match='read-back failed'):
        runner.run('auth-bootstrap', PASSWORD)
    assert victims == [runner.accounts[0]['uid']]
    assert auth.users[victims[0]].custom_claims == runner.accounts[0]['claims']
    assert runner.journal.data['stages']['auth-bootstrap'] == 'FAILED'
    assert runner.run('cleanup')['status'] == 'PARTIAL' and not auth.deleted


def test_missing_creation_timestamp_blocks_claims(setup_run, monkeypatch):
    runner, auth, _ = setup_run
    original = auth.create_user
    def unconfirmed(**kwargs):
        user = original(**kwargs)
        user.user_metadata.creation_timestamp = None
        return user
    monkeypatch.setattr(auth, 'create_user', unconfirmed)
    with pytest.raises(ValueError, match='timestamp'):
        runner.run('auth-bootstrap', PASSWORD)
    assert not auth.claim_updates


def test_restarted_process_does_not_restore_deletion_authority_from_journal(setup_run):
    runner, auth, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    runner.run('rtdb-bootstrap')
    other = Lifecycle(cli, runner.config, runner.case_id, runner.journal.path, auth_client=auth, storage=db)
    before = {path: db.get(path) for path in runner.journal.data['records']}
    result = other.run('cleanup')
    assert result['status'] == 'PARTIAL'
    assert all(item['status'] == 'MANUAL_REQUIRED' for item in result['resources'])
    assert all(db.get(path) == value for path, value in before.items())
    assert not auth.deleted


def test_changed_receipt_payload_cannot_be_reauthorized_by_journal(setup_run):
    runner, _, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    runner.run('rtdb-bootstrap')
    logical = '/drivers/' + runner.scope.uid('driver-502')
    changed = {'foreign': True}
    db.set(logical, changed)
    data = json.loads(runner.journal.path.read_text())
    data['records'][logical]['expected'] = changed
    runner.journal.path.write_text(json.dumps(data))
    result = runner.run('cleanup')
    assert db.get(logical) == changed
    assert any(item['target'] == runner.scope.storage_path(logical) and
               item['status'] == 'MANUAL_REQUIRED' for item in result['resources'])


def test_same_process_created_driver_leaves_are_cleaned_with_evidence(setup_run):
    runner, auth, db = setup_run
    runner.run('auth-bootstrap', PASSWORD)
    runner.run('rtdb-bootstrap')
    result = runner.run('cleanup')
    for driver in runner.drivers:
        assert db.get('/drivers/' + driver) is None
    assert sum(item['status'] == 'PASS' for item in result['resources']) == 3
    assert result['status'] == 'PARTIAL' and len(auth.users) == 4


def test_backend_snapshot_readback_is_not_creation_authority(setup_run):
    runner, _, db = setup_run
    logical = '/v3GuidanceSessions/v3-' + 'c' * 32
    value = {'sessionId': 'v3-' + 'c' * 32, 'state': 'IDLE'}
    db.set(logical, value)
    with runner.journal.locked():
        runner.backend_intent(logical)
        runner.record_backend_result(logical, value)
    assert runner.run('cleanup')['status'] == 'PARTIAL'
    assert db.get(logical) == value


def test_cleanup_adc_must_not_be_bootstrap(setup_run, tmp_path, monkeypatch):
    runner, _, _ = setup_run
    path = tmp_path / 'synthetic-adc.json'
    base = 'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/'
    def write(name):
        path.write_text(json.dumps({'type': 'impersonated_service_account',
            'service_account_impersonation_url': base + name + '@' + runner.scope.project_id +
            '.iam.gserviceaccount.com:generateAccessToken'}))
    monkeypatch.setenv('GOOGLE_APPLICATION_CREDENTIALS', str(path))
    write('mobi-ct-bootstrap')
    with pytest.raises(ValueError):
        cli.validate_stage_credential('cleanup', runner.config)
    write('mobi-ct-cleanup')
    cli.validate_stage_credential('cleanup', runner.config)  # Offline JSON validation only.
