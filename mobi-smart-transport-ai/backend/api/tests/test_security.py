"""Security boundary tests: SDK stub, real dependencies/routes/service checks."""
from types import SimpleNamespace
import time
import json
from pathlib import Path

import pytest
from fastapi import HTTPException
from fastapi.routing import APIRoute, APIWebSocketRoute
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect
from app.main import app
from app import security
from app.services.firebase_client import get_firebase_client
from app.services.v3_guidance_store import v3_guidance_store

pytestmark = pytest.mark.auth_boundary


@pytest.fixture
def client(monkeypatch):
    assert get_firebase_client().using_mock
    previous = dict(app.dependency_overrides)
    app.dependency_overrides.clear()
    get_firebase_client().clear_mock_store()
    v3_guidance_store.clear()
    monkeypatch.setattr(security, 'firebase_auth_app', lambda: object())
    def verify(token, **kwargs):
        assert kwargs['check_revoked'] is True
        assert kwargs['clock_skew_seconds'] == 0
        if token == 'invalid':
            raise security.auth.InvalidIdTokenError('invalid')
        return {'uid': token, 'exp': time.time()+3600, 'mobi_role': 'admin'}
    accounts = {
        'alice': ('passenger', None), 'bob': ('passenger', None),
        'driver-login-a': ('driver', 'fleet-a'), 'driver-login-b': ('driver', 'fleet-b'),
        'admin': ('admin', None), 'unprovisioned': (None, None),
        'unmapped-driver': ('driver', None),
    }
    monkeypatch.setattr(security.auth, 'verify_id_token', verify)
    def get_user(uid, **kwargs):
        role, driver = accounts[uid]
        return SimpleNamespace(disabled=False, custom_claims={'mobi_role': role, 'mobi_driver_id': driver})
    monkeypatch.setattr(security.auth, 'get_user', get_user)
    marker = security.current_principal.set(None)
    with TestClient(app) as result:
        yield result
    security.current_principal.reset(marker)
    app.dependency_overrides.clear()
    app.dependency_overrides.update(previous)
    get_firebase_client().clear_mock_store()
    v3_guidance_store.clear()


def headers(uid):
    return {'Authorization': 'Bearer '+uid}


def create(client, uid='alice'):
    get_firebase_client().set('/drivers/fleet-a', {'routeId': 'route', 'busNo': '502'})
    response = client.post('/ride-requests', headers=headers(uid), json={
        'userId': uid, 'stopId': 'stop', 'routeId': 'route', 'busNo': '502', 'targetDriverId': 'fleet-a'})
    assert response.status_code == 200
    return response.json()['requestId']


def test_every_business_route_has_explicit_policy():
    operations = set()
    for route in app.routes:
        if isinstance(route, APIRoute):
            operations.update((method, route.path) for method in route.methods)
        elif isinstance(route, APIWebSocketRoute):
            operations.add(('WS', route.path))
    assert operations == set(security.POLICY) | security.PUBLIC


def test_seven_previously_unauthorized_paths_are_blocked(client):
    rid = create(client)
    attempts = [
        ('POST', '/ride-requests', {'json': {'userId':'bob','stopId':'stop','routeId':'route','busNo':'502'}}),
        ('GET', '/ride-requests/'+rid, {}),
        ('GET', '/drivers/fleet-a/ride-requests', {}),
        ('GET', '/driver/ride-requests?driverId=fleet-a', {}),
        ('GET', '/ride-requests/'+rid, {'headers':headers('invalid')}),
        ('PATCH','/driver/ride-requests/'+rid+'/status',{'json':{'status':'ACCEPTED'}}),
        ('PATCH','/ride-requests/'+rid+'/status',{'json':{'status':'CANCELLED'}}),
    ]
    for method, path, kwargs in attempts:
        response = client.request(method,path,**kwargs)
        assert response.status_code == 401
        assert response.headers['www-authenticate'] == 'Bearer'


def test_roles_ownership_and_separate_driver_mapping(client):
    rid = create(client)
    for uid in ('bob','driver-login-b'):
        assert client.get('/ride-requests/'+rid,headers=headers(uid)).status_code == 403
        for prefix in ('/ride-requests/', '/driver/ride-requests/'):
            assert client.patch(prefix+rid+'/status',headers=headers(uid),json={'status':'ACCEPTED'}).status_code == 403
    for path in ('/drivers/fleet-a/ride-requests','/driver/ride-requests?driverId=fleet-a'):
        assert client.get(path,headers=headers('driver-login-b')).status_code == 403
        assert client.get(path,headers=headers('alice')).status_code == 403
        assert client.get(path,headers=headers('driver-login-a')).json()['requests'][0]['requestId'] == rid
    assert client.get('/ride-requests/'+rid,headers=headers('alice')).status_code == 200
    assert client.patch('/ride-requests/'+rid+'/status',headers=headers('alice'),json={'status':'ACCEPTED'}).status_code == 403
    assert client.patch('/driver/ride-requests/'+rid+'/status',headers=headers('driver-login-a'),json={'status':'ACCEPTED'}).status_code == 200
    assert client.patch('/ride-requests/'+rid+'/status',headers=headers('alice'),json={'status':'CANCELLED'}).status_code == 200


def test_forged_identity_and_assignment(client):
    payload={'userId':'bob','stopId':'stop','routeId':'route','busNo':'502','targetDriverId':'fleet-b'}
    assert client.post('/ride-requests',headers=headers('alice'),json=payload).status_code == 403
    payload['userId']='alice'
    assert client.post('/ride-requests',headers=headers('alice'),json=payload).status_code == 403
    assert client.post('/ride-requests',headers=headers('driver-login-a'),json=payload).status_code == 403
    for uid in ('unprovisioned','unmapped-driver'):
        assert client.get('/driver/ride-requests?driverId=fleet-a',headers=headers(uid)).status_code == 403


@pytest.mark.parametrize('kind',['invalid','expired','revoked','disabled','missing','network'])
def test_verifier_errors_fail_closed(client,monkeypatch,kind):
    errors = {
        'invalid': security.auth.InvalidIdTokenError('bad'),
        'expired': security.auth.ExpiredIdTokenError('expired',None),
        'revoked': security.auth.RevokedIdTokenError('revoked'),
        'disabled': security.auth.UserDisabledError('disabled'),
        'missing': security.auth.UserNotFoundError('missing'),
        'network': RuntimeError('sensitive internal details'),
    }
    def fail(*args,**kwargs):
        raise errors[kind]
    monkeypatch.setattr(security.auth,'verify_id_token',fail)
    response=client.get('/driver/ride-requests?driverId=fleet-a',headers=headers('alice'))
    assert response.status_code == (503 if kind=='network' else 401)
    assert 'sensitive' not in response.text


def test_current_account_disabled_and_role_changes(client,monkeypatch):
    monkeypatch.setattr(security.auth,'get_user',lambda *a,**k:SimpleNamespace(disabled=True))
    assert client.get('/firebase/status',headers=headers('admin')).status_code == 401
    monkeypatch.setattr(security.auth,'get_user',lambda *a,**k:SimpleNamespace(disabled=False,custom_claims={'mobi_role':'passenger'}))
    # Token stub carries old admin claim, current server role prevails.
    assert client.get('/firebase/status',headers=headers('admin')).status_code == 403
    def outage(*a,**k):
        raise RuntimeError('do not disclose')
    monkeypatch.setattr(security.auth,'get_user',outage)
    assert client.get('/firebase/status',headers=headers('admin')).status_code == 503


def test_mock_environment_is_not_auth_bypass(monkeypatch):
    monkeypatch.setenv('USE_MOCK_DATA','true')
    monkeypatch.setenv('FIREBASE_USE_MOCK','true')
    monkeypatch.setenv('FIREBASE_AUTH_EMULATOR_HOST','localhost:9099')
    with pytest.raises(HTTPException) as error:
        security.firebase_auth_app()
    assert error.value.status_code == 503
    monkeypatch.delenv('FIREBASE_AUTH_EMULATOR_HOST')
    monkeypatch.delenv('FIREBASE_PROJECT_ID',raising=False)
    with pytest.raises(HTTPException) as error:
        security.firebase_auth_app()
    assert error.value.status_code == 503


def test_guidance_session_ownership(client):
    response=client.post('/guidance/session',headers=headers('alice'),json={})
    assert response.status_code == 200
    sid=response.json()['sessionId']
    assert client.get('/guidance/state',params={'sessionId':sid},headers=headers('alice')).status_code==200
    assert client.get('/guidance/state',params={'sessionId':sid},headers=headers('bob')).status_code==403
    assert client.post('/guidance/reset',json={'sessionId':sid,'event':'RESET'},headers=headers('bob')).status_code==403
    assert client.post('/guidance/session',json={'sessionId':sid},headers=headers('bob')).status_code==403
    assert client.get('/guidance/state?sessionId=unknown',headers=headers('bob')).status_code==404
    assert client.get('/beacon/decision',params={'sessionId':sid},headers=headers('bob')).status_code==403


def test_internal_admin_only_and_production_mock_disabled(client,monkeypatch):
    assert client.get('/firebase/status').status_code==401
    assert client.get('/firebase/status',headers=headers('alice')).status_code==403
    assert client.get('/firebase/status',headers=headers('admin')).status_code==200
    monkeypatch.setenv('APP_ENV','production')
    assert client.post('/mock/geofence',headers=headers('admin'),json={}).status_code==403


def test_websocket_unauthenticated(client):
    for path in ('/agent/converse/live','/agent/tts/live','/agent/stt/live'):
        with pytest.raises(WebSocketDisconnect) as error:
            with client.websocket_connect(path):
                pass
        assert error.value.code==1008


def test_websocket_foreign_session(client):
    sid=client.post('/guidance/session',headers=headers('alice'),json={}).json()['sessionId']
    with client.websocket_connect('/agent/converse/live',headers=headers('bob')) as ws:
        ws.send_json({'sessionId':sid,'utterance':'hello'})
        with pytest.raises(WebSocketDisconnect) as error:
            ws.receive_json()
        assert error.value.code==1008


def test_service_requires_identity():
    from app.services.ride_request_service import RideRequestService
    assert security.current_principal.get() is None
    with pytest.raises(HTTPException) as error:
        RideRequestService().get('anything')
    assert error.value.status_code==401


def test_rtdb_sensitive_reads_closed():
    rules=json.loads((Path(__file__).resolve().parents[3]/'infrastructure/firebase/database.rules.json').read_text())['rules']
    assert rules['rideRequests']['.read'] is False
    assert rules['v3GuidanceSessions']['$sessionId']['.read'] is False
    assert rules['drivers']['$driverId']['.read'] is False
    assert 'mobi_driver_id' in rules['drivers']['$driverId']['currentLocation']['.write']


def test_named_auth_app_does_not_prevent_storage_initialization(monkeypatch, tmp_path):
    from app.services.firebase_client import FirebaseClient, FirebaseSettings
    import firebase_admin
    credential = tmp_path / "placeholder.json"
    credential.write_text("{}")
    storage = FirebaseClient(FirebaseSettings("project", "https://example.invalid", credential, None, False))
    calls = []
    from types import SimpleNamespace
    registry = {}
    def get_app(name="[DEFAULT]"):
        if name == "[DEFAULT]" and name not in registry:
            raise ValueError("no default app")
        return registry.get(name, object())
    monkeypatch.setattr(firebase_admin, "get_app", get_app)
    monkeypatch.setattr(security.credentials, "Certificate", lambda _: object())
    def initialize(*a, **k):
        calls.append((a,k))
        app = SimpleNamespace(name='[DEFAULT]', project_id=a[1]['projectId'], options=a[1])
        registry[app.name] = app
        return app
    monkeypatch.setattr(firebase_admin, "initialize_app", initialize)
    assert storage.initialize() is True
    assert len(calls) == 1


def test_navigation_rejects_foreign_session_before_tools(client):
    sid = client.post('/guidance/session', headers=headers('alice'), json={}).json()['sessionId']
    response = client.get('/navigation/live-status', headers=headers('bob'),
                          params={'sessionId':sid, 'routeNo':'502', 'boardStopId':'stop'})
    assert response.status_code == 403


def test_websocket_expired_connection_closes(client, monkeypatch):
    async def expired(_connection):
        return security.Principal('alice', 'passenger', expires_at=time.time()-1)
    app.dependency_overrides[security.get_principal] = expired
    # Annotated HTTPConnection is required by FastAPI dependency parsing.
    expired.__annotations__['_connection'] = security.HTTPConnection
    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect('/agent/converse/live') as ws:
            ws.receive_json()
    assert error.value.code == 1008


def test_geofence_cannot_write_another_passenger(client):
    response=client.post('/geofence/check',headers=headers('alice'),json={
        'userId':'bob','stopId':'stop','lat':36.6,'lng':127.4,
        'timestamp':'2026-10-11T00:00:00Z'})
    assert response.status_code==403
    assert get_firebase_client().get('/users/bob/currentLocation') is None


def test_openapi_marks_protected_operations(client):
    schema = client.get('/openapi.json').json()
    assert schema['paths']['/ride-requests']['post']['security']==[{'FirebaseIdToken':[]}]
    assert not schema['paths']['/health']['get'].get('security')


def test_navigation_cache_is_scoped_by_user_and_session(client):
    from app.services import live_status_service
    live_status_service._CACHE.clear()
    sessions={uid:client.post('/guidance/session',headers=headers(uid),json={}).json()['sessionId'] for uid in ('alice','bob')}
    for uid, sid in sessions.items():
        response=client.get('/navigation/live-status',headers=headers(uid),params={
            'routeNo':'502','boardStopId':'mock-stop-001','sessionId':sid,'mode':'mock'})
        assert response.status_code==200
        assert response.json()['sessionId']==sid
    assert {key[0] for key in live_status_service._CACHE} == {'alice','bob'}
    live_status_service._CACHE.clear()


@pytest.mark.parametrize("role", [None, [], "operator"])
def test_invalid_server_role_fails_closed(client, monkeypatch, role):
    monkeypatch.setattr(security.auth, 'get_user', lambda *a, **k: SimpleNamespace(
        disabled=False, custom_claims={'mobi_role':role}))
    assert client.get('/firebase/status', headers=headers('admin')).status_code == 403


def test_certificate_fetch_outage_is_503(client, monkeypatch):
    def fail(*a, **k):
        raise security.auth.CertificateFetchError('internal certificate transport details')
    monkeypatch.setattr(security.auth, 'verify_id_token', fail)
    response = client.get('/firebase/status', headers=headers('admin'))
    assert response.status_code == 503
    assert 'transport details' not in response.text


@pytest.mark.parametrize("expiry", [None, False, 0, -1, float("nan"), float("inf"), "9999999999"])
def test_expiry_required_even_when_sdk_accepts_emulator_token(client, monkeypatch, expiry):
    monkeypatch.setattr(security.auth, "verify_id_token", lambda *a, **k: {"uid": "alice", "exp": expiry})
    response = client.get("/guidance/state", headers={"Authorization": "Bearer alice"})
    assert response.status_code == 401
