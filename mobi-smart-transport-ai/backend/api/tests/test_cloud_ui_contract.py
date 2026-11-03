"""Synthetic UI data run is registered only inside monkeypatched offline tests."""
import json
from pathlib import Path
from types import MappingProxyType

import pytest

from app import cloud_test
from scripts import cloud_test as cli

FIXTURE = Path(__file__).resolve().parents[3] / 'shared/contracts/fixtures/cloud_ride_ui_offline.json'


def config(registered=False):
    source = FIXTURE.with_name('cloud_ride_ui_target.json') if registered else FIXTURE
    data = json.loads(source.read_text())
    registration = dict(cloud_test.CONFIRMED_TEST_PROJECTS[data['projectId']])
    return data, {**registration, 'authRunId': data['authRunId'],
                  'dataRunId': data['dataRunId'], 'runId': data['dataRunId'],
                  'executionMode': 'ride-only', 'backendPort': 8023,
                  'passengerPort': 5193, 'driverPort': 5194}


def test_synthetic_run_is_not_registered_for_cloud():
    data, value = config()
    assert (data['projectId'], data['dataRunId']) not in cloud_test.REVIEWED_REUSE_RUNS
    # configure is deliberately not called: no process environment is changed.
    assert data['offlineOnly'] is True
    assert data['dataRunId'] != 'rtdb-20261025-6e9a7c42'


@pytest.mark.parametrize('registered', [False, True])
def test_ui_fixture_matches_exact_existing_server_contract(monkeypatch, registered):
    data, value = config(registered)
    if registered:
        with pytest.raises(cloud_test.CloudTestConfigurationError, match='Retired Data run'):
            cli.execution_plan(value, data['caseId'])
        return
    if not registered:
        reviewed = dict(cloud_test.REVIEWED_REUSE_RUNS)
        reviewed[(data['projectId'], data['dataRunId'])] = (data['authRunId'], data['caseId'])
        monkeypatch.setattr(cloud_test, 'REVIEWED_REUSE_RUNS', MappingProxyType(reviewed))
    plan = cli.execution_plan(value, data['caseId'])
    assert plan['requestId'] == data['requestId']
    assert plan['idempotencyKey'] == data['idempotencyKey']
    assert plan['rideCreatePayload'] == {
        'userId': 'ct-' + data['authRunId'] + '-passenger-a',
        'stopId': data['stopId'], 'routeId': data['routeId'], 'busNo': data['busNo']}
    assert len(plan['allowedStorageMutations']) == 4
    assert all(path.startswith('/cloudTestRuns/' + data['dataRunId'] + '/')
               for path in plan['allowedStorageMutations'])
    assert not any('fcmTokens' in path or 'v3GuidanceSessions' in path
                   for path in plan['allowedStorageMutations'])
    base = '/cloudTestRuns/' + data['dataRunId']
    prefix = 'ct-' + data['authRunId']
    assert plan['allowedStorageMutations'] == [base + '/manifest',
        base + '/data/drivers/' + prefix + '-driver-502',
        base + '/data/drivers/' + prefix + '-driver-105',
        base + '/data/rideRequests/' + data['requestId']]


@pytest.mark.parametrize('change', ['run', 'project', 'auth'])
@pytest.mark.parametrize('registered', [False, True])
def test_unreviewed_ui_binding_cannot_validate(monkeypatch, change, registered):
    data, value = config(registered)
    if change == 'run':
        value['dataRunId'] = value['runId'] = 'rtdb-unreviewed-fixture'
    elif change == 'project':
        value['projectId'] = 'mobi-smart-transport'
    else:
        value['authRunId'] = 'auth-unreviewed-fixture'
    for key, val in cli.environment_for(value).items():
        monkeypatch.setenv(key, val)
    with pytest.raises(cloud_test.CloudTestConfigurationError):
        cloud_test.validate()


def test_no_live_registered_target_and_historical_contract_paths_remain_fixed():
    data, value = config(True)
    active = {pair for pair in cloud_test.REVIEWED_REUSE_RUNS
              if pair[1] not in cloud_test.RETIRED_DATA_RUNS}
    assert active == set()
    assert cloud_test.REVIEWED_GENERAL_RUNS == frozenset()
    with pytest.raises(cloud_test.CloudTestConfigurationError):
        cli.execution_plan(value, 'altered-case')
    scope = cloud_test.CloudTestScope(data['projectId'], value['databaseUrl'],
        data['dataRunId'], False, data['authRunId'], True)
    with pytest.raises(cloud_test.CloudTestConfigurationError):
        scope.storage_path('/rideRequests/altered-request')


def test_retired_target_offline_preflight_blocked_before_credentials_or_http(monkeypatch, tmp_path, capsys):
    import google.auth
    import requests
    import httpx
    def forbidden(*a, **kw):
        pytest.fail('Offline registration check attempted credentials or HTTP')
    monkeypatch.setattr(google.auth, 'default', forbidden)
    monkeypatch.setattr(requests.Session, 'request', forbidden)
    monkeypatch.setattr(httpx.Client, 'request', forbidden)
    data, value = config(True)
    for key, val in cli.environment_for(value).items():
        monkeypatch.setenv(key, val)
    source = tmp_path / 'public-target.json'
    source.write_text(json.dumps(value), encoding='utf-8')
    assert cli.main(['preflight', '--config', str(source), '--case-id', data['caseId']]) == 1
    assert 'Retired Data run' in capsys.readouterr().err
