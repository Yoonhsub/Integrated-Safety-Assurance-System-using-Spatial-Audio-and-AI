"""Reviewed Auth reuse + ride-only E2E. All network/SDK work is replaced locally."""
from copy import deepcopy
import json
import os
import time
from types import SimpleNamespace
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi.testclient import TestClient
from firebase_admin.auth import UserNotFoundError

from app import cloud_test, security
from app.main import app
from app.services.firebase_client import InMemoryRealtimeDatabase
from app.services.fcm_service import FcmService
from app.services.ride_request_service import RideRequestService
from scripts import cloud_test as cli
from scripts.cloud_test_lifecycle import Lifecycle

pytestmark = pytest.mark.auth_boundary

AUTH = 'auth-20261023-919e07bd'
DATA = 'rtdb-20261025-6e9a7c42'
CASE = 'ride-e2e-01'
REGISTRATION = deepcopy(cloud_test.CONFIRMED_TEST_PROJECTS['mobi-auth-cloud-test'])


def config():
    c = deepcopy(REGISTRATION)
    c.update(runId=DATA, dataRunId=DATA, authRunId=AUTH, executionMode='ride-only',
             backendPort=8023, passengerPort=5193, driverPort=5194)
    return c


class ExistingAuth:
    def __init__(self, accounts):
        self.users = {a['uid']: SimpleNamespace(uid=a['uid'], email=a['email'],
                     custom_claims=deepcopy(a['claims']), disabled=False) for a in accounts}
        self.reads = []

    def get_user(self, uid):
        self.reads.append(uid)
        if uid not in self.users:
            raise UserNotFoundError('absent')
        return self.users[uid]

    def get_user_by_email(self, email):
        for u in self.users.values():
            if u.email == email:
                return u
        raise UserNotFoundError('absent')

    def create_user(self, **kw):
        pytest.fail('Auth creation forbidden')

    def set_custom_user_claims(self, *a, **kw):
        pytest.fail('Claims mutation forbidden')

    def delete_user(self, *a, **kw):
        pytest.fail('Auth deletion forbidden')


class StrictStore:
    """Use actual scope mapping, with every physical request checked before I/O."""
    using_mock = False
    is_initialized = True
    settings = SimpleNamespace(credentials_ready=True)

    def __init__(self, scope):
        self.scope = scope
        self.memory = InMemoryRealtimeDatabase()
        self.calls = []

    def physical(self, path, op):
        result = self.scope.storage_path(path)
        allowed = {self.scope.path+'/manifest',
                   self.scope.path+'/data/drivers/'+self.scope.uid('driver-502'),
                   self.scope.path+'/data/drivers/'+self.scope.uid('driver-105'),
                   self.scope.path+'/data/rideRequests/'+self.scope.request_id}
        if op == 'GET':
            allowed.add(self.scope.path+'/data/rideRequests')
        assert result in allowed, 'Unapproved physical storage request'
        self.calls.append((op, result))
        return result

    def get(self, path):
        return self.memory.get(self.physical(path, 'GET'))

    def transaction(self, path, transform):
        return self.memory.transaction(self.physical(path, 'CAS'), transform)

    def delete_if_unchanged(self, path, expected):
        physical = self.physical(path, 'CAS-DELETE')
        def delete(raw):
            if raw != expected:
                raise ValueError('ETag/content conflict')
            return None
        return self.memory.transaction(physical, delete)


@pytest.fixture
def setup(monkeypatch, tmp_path):
    for k in list(os.environ):
        if k.startswith(('MOBI_CLOUD_TEST', 'FIREBASE_', 'GOOGLE_', 'MOBI_LOCAL_DEMO')) or k in {
                'K_SERVICE', 'GAE_ENV', 'OPENAI_API_KEY', 'GEMINI_API_KEY'}:
            monkeypatch.delenv(k, raising=False)
    for k, v in cli.environment_for(config()).items():
        monkeypatch.setenv(k, v)
    monkeypatch.setattr(cloud_test, 'CONFIRMED_TEST_PROJECTS', {'mobi-auth-cloud-test': REGISTRATION})
    scope = cloud_test.validate()
    accounts, _, _ = cli.fixture(config())
    auth, store = ExistingAuth(accounts), StrictStore(scope)
    runner = Lifecycle(cli, config(), CASE, tmp_path/'journal.json', auth_client=auth, storage=store)
    return runner, auth, store


def test_reviewed_binding_and_plan_reuse_exact_four(setup, tmp_path):
    r, auth, db = setup
    plan = cli.execution_plan(config(), CASE)
    assert r.scope.identity_run == AUTH and r.scope.run_id == DATA
    assert [a['uid'] for a in r.accounts] == ['ct-'+AUTH+'-'+n for n in cli.NAMES]
    assert all(cloud_test.account_allowed(a['uid'], a['claims'], r.scope) for a in r.accounts)
    assert plan['newAuthAccounts'] == plan['maxGuidanceSessions'] == 0
    assert plan['fcmTokenReads']==0 and len(plan['allowedStorageMutations'])==4
    assert len(plan['allowedStorageReads'])==5
    assert plan['rideCreatePayload']['userId']=='ct-'+AUTH+'-passenger-a'
    assert plan['bootstrapIdentity'] == 'Runtime' and 'auth-bootstrap' not in plan['stages']
    assert len(plan['bootstrapDatabasePaths']+plan['smokeDatabasePaths']) == 4
    assert plan['requestId'] == r.scope.request_id
    path = tmp_path/'public.json';path.write_text(json.dumps(config()))
    assert cli.load_config(path) == config()
    assert r.run('auth-reuse-check')['authMutations'] == 0
    assert r.run('rtdb-bootstrap')['records'] == 3
    assert r.journal.data['accounts'] == {}
    assert db.get(r.scope.path)['authRunId'] == AUTH


@pytest.mark.parametrize('key,value', [('authRunId','auth-unknown-user'),
    ('dataRunId','rtdb-unapproved-run'), ('runId','rtdb-unapproved-run'),
    ('executionMode','legacy'), ('authRunId',123)])
def test_unreviewed_binding_rejected(setup, tmp_path, key, value):
    c=config();c[key]=value
    path=tmp_path/'bad.json';path.write_text(json.dumps(c))
    with pytest.raises(ValueError):cli.load_config(path)


@pytest.mark.parametrize('key,value', [('MOBI_CLOUD_TEST_AUTH_RUN_ID','other-auth-run'),
    ('MOBI_CLOUD_TEST_DATA_RUN_ID','other-data-run'), ('MOBI_CLOUD_TEST_MODE',''),
    ('MOBI_CLOUD_TEST_RUN_ID','../escape')])
def test_server_rejects_binding_env_change(setup, monkeypatch, key, value):
    monkeypatch.setenv(key,value)
    with pytest.raises(ValueError):cloud_test.validate()


@pytest.mark.parametrize('kind', ['uid','role','run','driver','extra','disabled','email'])
def test_existing_account_changes_fail_closed_before_data_write(setup, kind):
    r,auth,db=setup
    u=auth.users[r.accounts[2]['uid']]
    if kind=='uid':u.uid='foreign'
    elif kind=='role':u.custom_claims['mobi_role']='admin'
    elif kind=='run':u.custom_claims['mobi_cloud_test_run']=DATA
    elif kind=='driver':u.custom_claims['mobi_driver_id']='foreign'
    elif kind=='extra':u.custom_claims['admin']=True
    elif kind=='disabled':u.disabled=True
    else:u.email='foreign@example.test'
    with pytest.raises(ValueError):r.run('rtdb-bootstrap')
    assert not db.calls


@pytest.mark.parametrize('path', ['/fcmTokens/drivers/x','/v3GuidanceSessions/v3-'+'a'*32,
    '/users/x','/drivers/foreign','/rideRequests/foreign','/cloudTestRuns/other/manifest','/',
    '/rideRequests/../escape'])
def test_strict_paths_rejected_before_storage(setup,path):
    _,_,db=setup
    with pytest.raises(ValueError):db.get(path)
    assert not db.calls


def test_no_auth_bootstrap_or_legacy_smoke_in_reuse_mode(setup):
    r,_,db=setup
    for stage in ('auth-bootstrap','backend-smoke'):
        with pytest.raises(ValueError):r.run(stage,'not-a-real-password')
    assert not db.calls


def test_fcm_disabled_reads_no_token(setup):
    r,_,db=setup
    result=FcmService(db).send_ride_request_notification(driver_id=r.scope.uid('driver-502'),
        request_id=r.scope.request_id,user_id=r.accounts[0]['uid'],stop_id='test',route_id='MOCK-502',bus_no='502')
    assert not result.accepted and not db.calls


def test_regular_enabled_fcm_still_looks_up_and_sends(setup,monkeypatch):
    for k in list(os.environ):
        if k.startswith('MOBI_CLOUD_TEST'):monkeypatch.delenv(k)
    monkeypatch.setenv('FCM_ENABLED','true');monkeypatch.setenv('FCM_USE_MOCK','false')
    reads=[];sends=[]
    db=SimpleNamespace(using_mock=False,get=lambda p:(reads.append(p) or {
        'token':'fake-local-token','platform':'web','updatedAt':'2026-10-25T00:00:00Z'}))
    service=FcmService(db)
    from app.schemas.notification import NotificationResponse
    monkeypatch.setattr(service,'_send_with_firebase_messaging',lambda **kw:
        (sends.append(kw) or NotificationResponse(accepted=True,messageId='fake',detail='offline')))
    assert service.send_ride_request_notification(driver_id='driver',request_id='ride',user_id='p',
        stop_id='stop',route_id='route',bus_no='502').accepted
    assert reads==['/fcmTokens/drivers/driver'] and len(sends)==1


def test_offline_preflight_no_sdk_or_network(setup,tmp_path,monkeypatch,capsys):
    import google.auth,requests
    def forbidden(*a,**k):pytest.fail('Offline preflight attempted network/credentials')
    monkeypatch.setattr(google.auth,'default',forbidden)
    monkeypatch.setattr(requests.Session,'request',forbidden)
    monkeypatch.setattr(httpx.Client,'request',forbidden)
    path=tmp_path/'public.json';path.write_text(json.dumps(config()))
    assert cli.main(['preflight','--config',str(path),'--case-id',CASE])==0
    assert json.loads(capsys.readouterr().out)['networkPerformed'] is False


def test_restarted_cleanup_cannot_adopt_journal_receipts(setup,tmp_path):
    r,auth,db=setup;r.run('rtdb-bootstrap')
    before=len(db.calls)
    other=Lifecycle(cli,config(),CASE,r.journal.path,auth_client=auth,storage=db)
    result=other.run('cleanup')
    assert result['status']=='PARTIAL' and len(db.calls)==before
    assert all(x['status']=='MANUAL_REQUIRED' for x in result['resources'])


def test_ride_only_http_smoke_real_routes_no_unapproved_requests(setup,monkeypatch):
    r,auth,db=setup;r.run('rtdb-bootstrap')
    import importlib
    main_module=importlib.import_module('app.main')
    monkeypatch.setattr(main_module,'APP_ENV','staging')
    monkeypatch.setattr(main_module,'get_firebase_client',lambda:db)
    from app.api.routes import ride_requests,driver_ride_requests
    service=RideRequestService(db,FcmService(db))
    monkeypatch.setattr(ride_requests,'_service',service)
    monkeypatch.setattr(driver_ride_requests,'_service',service)
    monkeypatch.setattr(security,'firebase_auth_app',lambda:object())
    def verify(token,**kw):
        assert kw['check_revoked'] is True
        if token not in auth.users:raise ValueError('invalid')
        return {'uid':token,'exp':time.time()+3600}
    monkeypatch.setattr(security.auth,'verify_id_token',verify)
    monkeypatch.setattr(security.auth,'get_user',lambda uid,**kw:auth.get_user(uid))
    import requests,google.auth
    monkeypatch.setattr(google.auth,'default',lambda *a,**k:pytest.fail('ADC accessed'))
    monkeypatch.setattr(requests.Session,'request',lambda *a,**k:pytest.fail('Unexpected network'))
    events=[]
    with TestClient(app) as backend:
        def transport(req):
            if req.url.host=='identitytoolkit.googleapis.com':
                data=json.loads(req.content)
                user=auth.get_user_by_email(data['email'])
                return httpx.Response(200,json={'localId':user.uid,'idToken':user.uid,'refreshToken':user.uid})
            if req.url.host=='securetoken.googleapis.com':
                uid=parse_qs(req.content.decode())['refresh_token'][0]
                assert uid in auth.users
                return httpx.Response(200,json={'user_id':uid,'id_token':uid})
            assert req.url.host=='127.0.0.1' and req.url.port==8023
            assert req.url.path=='/health' or req.url.path.startswith(('/ride-requests','/drivers/'))
            response=backend.request(req.method,str(req.url),headers=dict(req.headers),content=req.content)
            events.append((req.method,req.url.path,response.status_code))
            return httpx.Response(response.status_code,json=response.json())
        original=httpx.Client
        monkeypatch.setattr(httpx,'Client',lambda **kw:original(transport=httpx.MockTransport(transport),**kw))
        result=r.run('ride-smoke','offline-placeholder-not-a-cloud-password')
        # Even a direct unsupported API request is denied before a service call.
        assert backend.post('/guidance/session',headers={'Authorization':'Bearer '+r.accounts[0]['uid']},json={}).status_code==403
    assert result['status']=='PASS' and result['guidanceSessionsCreated']==0
    assert {code for _,_,code in events}>={200,401,403,409}
    assert db.get('/rideRequests/'+r.scope.request_id)['status']=='CANCELLED'
    assert len(db.memory.get(r.scope.path+'/data/rideRequests'))==1
    assert not any('fcmTokens' in p or 'v3GuidanceSessions' in p for _,p in db.calls)
    assert any(m=='GET' and p=='/ride-requests/'+r.scope.request_id for m,p,_ in events)
    assert r.journal.data['accounts']=={}


def test_dropping_reuse_fields_cannot_downgrade_reviewed_data_run(setup, tmp_path):
    c=config()
    for key in ('authRunId','dataRunId','executionMode'):c.pop(key)
    path=tmp_path/'downgrade.json';path.write_text(json.dumps(c))
    with pytest.raises(ValueError):cli.load_config(path)


def test_runtime_read_only_preflight_checks_existing_accounts(setup):
    r,auth,db=setup
    assert r.run('preflight')['status']=='PASS'
    assert len(auth.reads)==4 and all(op=='GET' for op,_ in db.calls)
    assert not r.journal.data['accounts']


@pytest.mark.parametrize('stage', ['preflight','auth-reuse-check','rtdb-bootstrap','ride-smoke','backend'])
def test_reuse_stages_require_runtime_not_bootstrap_adc(setup, tmp_path, monkeypatch, stage):
    for target,accept in [('mobi-ct-runtime',True),('mobi-ct-bootstrap',False),('mobi-ct-cleanup',False)]:
        path=tmp_path/'fake-adc.json'
        path.write_text(json.dumps({'type':'impersonated_service_account',
            'service_account_impersonation_url':'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/'+target+'@mobi-auth-cloud-test.iam.gserviceaccount.com:generateAccessToken'}))
        monkeypatch.setenv('GOOGLE_APPLICATION_CREDENTIALS',str(path))
        if accept:cli.validate_stage_credential(stage,config())
        else:
            with pytest.raises(ValueError):cli.validate_stage_credential(stage,config())


def test_real_storage_adapter_rejects_outside_path_before_reference(setup,monkeypatch):
    r,_,_=setup
    from app.services.firebase_client import FirebaseClient,FirebaseSettings
    client=FirebaseClient(FirebaseSettings(r.scope.project_id,r.scope.database_url,None,None,False,True,True))
    monkeypatch.setattr(client,'initialize',lambda:True)
    refs=[]
    client._db_module=SimpleNamespace(reference=lambda p:refs.append(p))
    for p in ['/fcmTokens/drivers/x','/v3GuidanceSessions/v3-'+'a'*32,'/rideRequests/foreign']:
        with pytest.raises(ValueError):client._real_reference(p)
    assert not refs


@pytest.mark.parametrize('method,args', [('set', ({'x':1},)),('update', ({'x':1},)),
    ('push', ({'x':1},)),('delete', ())])
def test_unconditional_real_adapter_mutations_refused_before_io(setup,monkeypatch,method,args):
    r,_,_=setup
    from app.services.firebase_client import FirebaseClient,FirebaseSettings
    from fastapi import HTTPException
    client=FirebaseClient(FirebaseSettings(r.scope.project_id,r.scope.database_url,None,None,False,True,True))
    monkeypatch.setattr(client,'_use_memory',lambda:pytest.fail('Unconditional write reached I/O'))
    with pytest.raises(HTTPException) as exc:
        getattr(client,method)('/rideRequests/'+r.scope.request_id,*args)
    assert exc.value.status_code==403


def test_collection_cas_refused_before_io(setup,monkeypatch):
    r,_,_=setup
    from app.services.firebase_client import FirebaseClient,FirebaseSettings
    from fastapi import HTTPException
    client=FirebaseClient(FirebaseSettings(r.scope.project_id,r.scope.database_url,None,None,False,True,True))
    monkeypatch.setattr(client,'_use_memory',lambda:pytest.fail('Collection CAS reached I/O'))
    with pytest.raises(HTTPException) as exc:client.transaction('/rideRequests',lambda raw:{})
    assert exc.value.status_code==403


def test_forged_ride_journal_never_grants_cleanup_receipt(setup):
    r,_,db=setup;r.run('rtdb-bootstrap')
    logical='/rideRequests/'+r.scope.request_id
    physical=r.scope.storage_path(logical)
    db.memory.set(physical,{'existing':'not-created-by-runner'})
    with r.journal.locked():
        r.journal.data['records'][logical]={'state':'verified','physicalPath':physical,
            'expected':{'existing':'not-created-by-runner'}}
        r.journal.save()
    before=sum(1 for op,p in db.calls if p==physical)
    result=r.run('cleanup')
    assert result['status']=='PARTIAL'
    assert any(x['target']==physical and x['status']=='MANUAL_REQUIRED' for x in result['resources'])
    assert sum(1 for op,p in db.calls if p==physical)==before
    assert db.memory.get(physical)=={'existing':'not-created-by-runner'}
