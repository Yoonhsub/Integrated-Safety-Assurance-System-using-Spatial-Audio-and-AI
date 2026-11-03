"""Pre-I/O retirement attacks; all active registrations are synthetic fixtures."""
from copy import deepcopy
import json

import pytest

from app import cloud_test, security
from app.services import firebase_client
from scripts import cloud_test as cli

PROJECT = 'mobi-auth-cloud-test'
RETIRED = 'rtdb-20261025-6e9a7c42'
AUTH = 'auth-20261023-919e07bd'
FRESH = 'rtdb-offline-retire-fixt'
CASE = 'offline-case'


def config(run=RETIRED, ride=True):
    c = deepcopy(cloud_test.CONFIRMED_TEST_PROJECTS[PROJECT])
    c.update(runId=run, backendPort=8023, passengerPort=5193, driverPort=5194)
    if ride:
        c.update(authRunId=AUTH, dataRunId=run, executionMode='ride-only')
    return c


@pytest.fixture(autouse=True)
def no_sdk(monkeypatch):
    def forbidden(*a, **kw):
        pytest.fail('Firebase initialization/read attempted before configuration rejection')
    monkeypatch.setattr(security, 'firebase_auth_app', forbidden)
    monkeypatch.setattr(firebase_client, 'get_firebase_client', forbidden)
    for key in list(__import__('os').environ):
        if key.startswith(('MOBI_CLOUD_TEST', 'FIREBASE_', 'GOOGLE_')):
            monkeypatch.delenv(key, raising=False)


def environment(monkeypatch, c):
    for key, value in cli.environment_for(c).items():
        monkeypatch.setenv(key, value)


@pytest.mark.parametrize('retired', ['rtdb-20261025-6e9a7c42', 'rtdb-20261026-b742c9e1'])
@pytest.mark.parametrize('ride', [False, True], ids=['B1-general', 'B2-ride-only'])
def test_retired_run_is_blocked_even_when_reregistered(monkeypatch, tmp_path, ride, retired):
    # B3: deliberately leave/add the retired run to both positive registries.
    monkeypatch.setattr(cloud_test, 'REVIEWED_GENERAL_RUNS', frozenset({(PROJECT, retired)}))
    monkeypatch.setattr(cloud_test, 'REVIEWED_REUSE_RUNS', {(PROJECT, retired): (AUTH, CASE)})
    c = config(run=retired, ride=ride)
    environment(monkeypatch, c)
    source = tmp_path / 'public-config.json'
    source.write_text(json.dumps(c), encoding='utf-8')
    for operation in (lambda: cloud_test.ensure_execution_run(PROJECT, retired,
                          AUTH if ride else '', retired if ride else '', 'ride-only' if ride else ''),
                      cloud_test.validate, cloud_test.create_app,
                      lambda: cli.configure(c), lambda: cli.plan(c, CASE),
                      lambda: cli.load_config(source)):
        with pytest.raises(cloud_test.CloudTestConfigurationError, match='Retired Data run'):
            operation()


@pytest.mark.parametrize('ride', [False, True])
def test_B4_unregistered_run_rejected_without_sdk(monkeypatch, ride):
    c = config(FRESH, ride)
    environment(monkeypatch, c)
    with pytest.raises(cloud_test.CloudTestConfigurationError):
        cloud_test.create_app()
    with pytest.raises(cloud_test.CloudTestConfigurationError):
        cli.plan(c, CASE)


@pytest.mark.parametrize('ride', [False, True])
def test_B5_reviewed_synthetic_run_preserves_future_registration(monkeypatch, ride):
    monkeypatch.setattr(cloud_test, 'REVIEWED_GENERAL_RUNS', frozenset({(PROJECT, FRESH)}))
    monkeypatch.setattr(cloud_test, 'REVIEWED_REUSE_RUNS', {(PROJECT, FRESH): (AUTH, CASE)} if ride else {})
    c = config(FRESH, ride)
    environment(monkeypatch, c)
    scope = cloud_test.validate()
    assert scope.run_id == FRESH
    assert scope.identity_run == (AUTH if ride else FRESH)
    p = cli.plan(c, CASE)
    assert all(path.startswith('/cloudTestRuns/' + FRESH + '/')
               for path in p['bootstrapDatabasePaths'] + p['smokeDatabasePaths'])
    assert AUTH not in cloud_test.RETIRED_DATA_RUNS


@pytest.mark.parametrize('mutation', ['project', 'auth', 'data', 'mode', 'run', 'url'])
def test_B6_registered_fixture_tampering_fails_before_sdk(monkeypatch, mutation):
    monkeypatch.setattr(cloud_test, 'REVIEWED_REUSE_RUNS', {(PROJECT, FRESH): (AUTH, CASE)})
    c = config(FRESH)
    if mutation == 'project':
        c['projectId'] = 'mobi-smart-transport'
    elif mutation == 'auth':
        c['authRunId'] = 'auth-unreviewed-fixture'
    elif mutation == 'data':
        c['dataRunId'] = RETIRED
    elif mutation == 'mode':
        c['executionMode'] = 'general'
    elif mutation == 'run':
        c['runId'] = RETIRED
    elif mutation == 'url':
        c['databaseUrl'] = cloud_test.MAIN_DATABASE_URL
    environment(monkeypatch, c)
    with pytest.raises(cloud_test.CloudTestConfigurationError):
        cloud_test.create_app()
