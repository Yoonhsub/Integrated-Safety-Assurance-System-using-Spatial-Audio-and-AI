"""Synthetic UI data run is registered only inside monkeypatched offline tests."""
import json
from pathlib import Path
from types import MappingProxyType

import pytest

from app import cloud_test
from scripts import cloud_test as cli

FIXTURE = Path(__file__).resolve().parents[3] / 'shared/contracts/fixtures/cloud_ride_ui_offline.json'


def config():
    data = json.loads(FIXTURE.read_text())
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


def test_ui_fixture_matches_exact_existing_server_contract(monkeypatch):
    data, value = config()
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


@pytest.mark.parametrize('change', ['run', 'project', 'auth'])
def test_unreviewed_ui_binding_cannot_validate(monkeypatch, change):
    data, value = config()
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
