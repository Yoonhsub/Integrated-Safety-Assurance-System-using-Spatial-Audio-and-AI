"""Cloud-test boundaries using SDK stubs / explicit memory storage. No cloud writes."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import time
from types import SimpleNamespace

from fastapi import HTTPException
from fastapi.testclient import TestClient
import pytest

from app import cloud_test, security
from app.main import app
from app.services.firebase_client import FirebaseClient, FirebaseSettings
from app.services.ride_request_service import RideRequestService
from app.schemas.ride_request import RideRequestCreate, RideRequestStatus
from scripts import cloud_test as cli

pytestmark=pytest.mark.auth_boundary
_CONSOLE_REGISTRATIONS=cloud_test.CONFIRMED_TEST_PROJECTS


def config():
    project='mobi-cloud-test'
    def web(name):return {'MOBI_FIREBASE_API_KEY':'public-test-key','MOBI_FIREBASE_APP_ID':'1:123:web:'+('a'*24 if name=='passenger' else 'b'*24),
        'MOBI_FIREBASE_MESSAGING_SENDER_ID':'123','MOBI_FIREBASE_PROJECT_ID':project,
        'MOBI_FIREBASE_AUTH_DOMAIN':project+'.firebaseapp.com'}
    return {'projectId':project,'databaseUrl':'https://mobi-cloud-test-default-rtdb.firebaseio.com',
            'runId':'trial-20261019-a','backendPort':8011,'passengerPort':5183,'driverPort':5184,
            'passenger':web('passenger'),'driver':web('driver')}


def register_synthetic_project(monkeypatch, c):
    from copy import deepcopy
    record={key:deepcopy(c[key]) for key in ('projectId','databaseUrl','passenger','driver')}
    monkeypatch.setattr(cloud_test,'CONFIRMED_TEST_PROJECTS',{c['projectId']:record})


@pytest.fixture(autouse=True)
def synthetic_registration_only(monkeypatch):
    register_synthetic_project(monkeypatch,config())


@pytest.fixture
def environment(monkeypatch):
    for key in list(os.environ):
        if key.startswith(('MOBI_CLOUD_TEST','FIREBASE_','GOOGLE_','MOBI_LOCAL_DEMO')) or key in {'K_SERVICE','GAE_ENV','OPENAI_API_KEY','GEMINI_API_KEY'}:
            monkeypatch.delenv(key,raising=False)
    c=config()
    for key,value in cli.environment_for(c).items():monkeypatch.setenv(key,value)
    return c


def test_exact_test_target_and_regional_database(environment,monkeypatch):
    assert cloud_test.validate().project_id=='mobi-cloud-test'
    url='https://mobi-cloud-test-default-rtdb.asia-southeast1.firebasedatabase.app'
    monkeypatch.setenv('FIREBASE_DATABASE_URL',url);monkeypatch.setenv('MOBI_CLOUD_TEST_DATABASE_URL',url)
    from copy import deepcopy
    confirmed=deepcopy(environment);confirmed['databaseUrl']=url
    register_synthetic_project(monkeypatch,confirmed)
    assert cloud_test.validate().database_url==url


@pytest.mark.parametrize('key,value',[
    ('MOBI_CLOUD_TEST','0'),('APP_ENV','production'),('APP_ENV','development'),
    ('FIREBASE_PROJECT_ID','mobi-smart-transport'),('GOOGLE_CLOUD_PROJECT','different-cloud-test'),
    ('FIREBASE_USE_MOCK','true'),('FIREBASE_USE_ADC','false'),('MOBI_LOCAL_DEMO','1'),
    ('FIREBASE_AUTH_EMULATOR_HOST','127.0.0.1:9099'),('FIREBASE_DATABASE_EMULATOR_HOST','false'),
    ('FIREBASE_SERVICE_ACCOUNT_PATH','key.json'),('K_SERVICE','cloud'),('GAE_ENV','standard'),
    ('MOBI_CLOUD_TEST_PROJECT_ID','mobi-smart-transport'),('MOBI_CLOUD_TEST_RUN_ID','../escape'),
    ('BACKEND_CORS_ORIGINS','*'),('BACKEND_CORS_ORIGINS','https://production.web.app'),
    ('BACKEND_CORS_ORIGINS','http://127.0.0.1:5173'),('FCM_ENABLED','true'),
    ('PUBLIC_DATA_USE_MOCK','false'),('OPENAI_API_KEY','sensitive-not-logged'),
])
def test_mixed_or_unsafe_environment_rejected(environment,monkeypatch,key,value):
    monkeypatch.setenv(key,value)
    with pytest.raises(ValueError):cloud_test.validate()


@pytest.mark.parametrize('url',[
    'http://mobi-cloud-test-default-rtdb.firebaseio.com',
    'https://production-default-rtdb.firebaseio.com',
    'https://mobi-cloud-test-default-rtdb.firebaseio.com.evil.test',
    'https://mobi-cloud-test-default-rtdb.firebaseio.com/path',
    'https://mobi-cloud-test-default-rtdb.firebaseio.com?ns=production',
    'https://user:password@mobi-cloud-test-default-rtdb.firebaseio.com',
    'https://mobi-cloud-test-default-rtdb.firebaseio.com:443',
])
def test_database_host_scope_rejected(environment,monkeypatch,url):
    monkeypatch.setenv('FIREBASE_DATABASE_URL',url);monkeypatch.setenv('MOBI_CLOUD_TEST_DATABASE_URL',url)
    with pytest.raises(ValueError):cloud_test.validate()


def test_partial_marker_fails_closed_before_auth(environment,monkeypatch):
    monkeypatch.delenv('MOBI_CLOUD_TEST')
    with pytest.raises(HTTPException) as e:security.firebase_auth_app()
    assert e.value.status_code==503


def test_role_current_claims_and_run_scope(environment,monkeypatch):
    scope=cloud_test.validate();claims={'mobi_role':'passenger','mobi_cloud_test_run':scope.run_id}
    monkeypatch.setattr(security,'firebase_auth_app',lambda:object())
    monkeypatch.setattr(security.auth,'verify_id_token',lambda *a,**k:{'uid':scope.uid('passenger-a'),'exp':time.time()+3600,'mobi_role':'admin'})
    monkeypatch.setattr(security.auth,'get_user',lambda *a,**k:SimpleNamespace(disabled=False,custom_claims=claims))
    assert security.verify_user('opaque').role=='passenger'
    claims['mobi_cloud_test_run']='other-run'
    with pytest.raises(HTTPException) as e:security.verify_user('opaque')
    assert e.value.status_code==403


def test_existing_emulator_process_not_repurposed(environment,monkeypatch):
    monkeypatch.setenv('FIREBASE_AUTH_EMULATOR_HOST','127.0.0.1:9099')
    before=dict(os.environ)
    with pytest.raises(ValueError):cli.configure(config())
    assert dict(os.environ)==before


def test_cli_plan_and_prepare_are_offline(tmp_path,monkeypatch,capsys):
    c=config();path=tmp_path/'public.json';path.write_text(json.dumps(c))
    monkeypatch.setattr(cli,'bootstrap',lambda *a:pytest.fail('unexpected network/bootstrap'))
    assert cli.main(['bootstrap','--config',str(path)])==0
    plan=json.loads(capsys.readouterr().out)
    assert plan['networkPerformed'] is False and len(plan['authAccounts'])==4
    output=tmp_path/'public-defines'
    assert cli.main(['prepare','--config',str(path),'--output',str(output)])==0
    defines=json.loads((output/'passenger-defines.json').read_text())
    assert defines['MOBI_LOCAL_DEMO']=='false' and defines['MOBI_API_BASE_URL']=='http://127.0.0.1:8011'
    assert not any('password' in p.name for p in output.iterdir())


def test_apply_requires_matching_approval_and_sanitizes_errors(tmp_path,monkeypatch,capsys):
    path=tmp_path/'public.json';path.write_text(json.dumps(config()))
    monkeypatch.setattr(cli,'bootstrap',lambda *a:pytest.fail('unexpected write'))
    assert cli.main(['bootstrap','--config',str(path),'--apply'])==1
    assert 'Cloud-test failed closed' in capsys.readouterr().err


@pytest.mark.parametrize('change',[{'private_key':'never-copy'}, {'backendPort':8001}, {'projectId':'mobi-smart-transport'}])
def test_public_config_refuses_secrets_demo_ports_and_real_target(tmp_path,change):
    path=tmp_path/'public.json';path.write_text(json.dumps({**config(),**change}))
    with pytest.raises(ValueError):cli.load_config(path)


def test_legacy_seed_route_and_service_block_before_initialization(environment,monkeypatch):
    from app.api.routes import firebase_admin as route
    from app.services.firebase_demo_seed_service import FirebaseDemoSeedService
    monkeypatch.setattr(route,'get_firebase_client',lambda:pytest.fail('seed touched storage'))
    with pytest.raises(HTTPException) as e:route.firebase_initialize(route.FirebaseInitializeRequest(reset=True))
    assert e.value.status_code==403
    with pytest.raises(HTTPException):FirebaseDemoSeedService(object()).seed(reset=False)


def test_cloud_status_uses_read_only_probe(environment,monkeypatch):
    from app.api.routes import firebase_admin as route
    storage=SimpleNamespace(initialize=lambda:True,
        status=lambda:dict(credentialsReady=True,serviceAccountExists=False,usingMock=False,
            runtimeMode='firebase-admin',initialized=True,projectId='mobi-cloud-test',databaseUrl='test',serviceAccountPath=None,lastError=None),
        get=lambda p:None,probe=lambda:pytest.fail('write probe called'))
    monkeypatch.setattr(route,'get_firebase_client',lambda:storage)
    assert route.firebase_status()['probe']['message']=='Read-only cloud-test storage check'


def dispatch(environment):
    accounts,drivers,manifest=cli.fixture(environment)
    memory=FirebaseClient(FirebaseSettings(None,None,None,None,True))
    scope=cloud_test.validate();memory.set(scope.path,manifest)
    for key,value in drivers.items():memory.set('/drivers/'+key,value)
    service=RideRequestService(memory,SimpleNamespace(send_ride_request_notification=lambda **k:SimpleNamespace(accepted=False)))
    payload=RideRequestCreate(userId=accounts[0]['uid'],stopId='ct-stop',routeId='MOCK-502',busNo='502')
    return scope,memory,service,payload


def test_server_assignment_and_concurrent_idempotency(environment):
    scope,memory,service,payload=dispatch(environment)
    def create(_):
        token=security.current_principal.set(security.Principal(scope.uid('passenger-a'),'passenger'))
        try:return service.create(payload,'cloud-test-idempotent-key')
        finally:security.current_principal.reset(token)
    with ThreadPoolExecutor(max_workers=4) as pool:rows=list(pool.map(create,range(8)))
    assert len({r.requestId for r in rows})==1
    assert all(r.targetDriverId==scope.uid('driver-502') for r in rows)
    token=security.current_principal.set(security.Principal(scope.uid('driver-a'),'driver',scope.uid('driver-502')))
    try:assert service.update_status(rows[0].requestId,RideRequestStatus.ACCEPTED).status==RideRequestStatus.ACCEPTED
    finally:security.current_principal.reset(token)
    token=security.current_principal.set(security.Principal(scope.uid('passenger-a'),'passenger'))
    try:
        service.update_status(rows[0].requestId,RideRequestStatus.CANCELLED)
        assert service.create(payload,'cloud-test-idempotent-key').status==RideRequestStatus.CANCELLED
    finally:security.current_principal.reset(token)


@pytest.mark.parametrize('kind',['forged-driver','wrong-bus','missing-run','bad-profile'])
def test_cloud_dispatch_failures_do_not_write_request(environment,kind):
    scope,memory,service,payload=dispatch(environment)
    if kind=='forged-driver':payload=payload.model_copy(update={'targetDriverId':scope.uid('driver-105')})
    if kind=='wrong-bus':payload=payload.model_copy(update={'busNo':'105'})
    if kind=='missing-run':memory.delete(scope.path)
    if kind=='bad-profile':memory.set('/drivers/'+scope.uid('driver-502'),{'routeId':payload.routeId,'busNo':'502'})
    token=security.current_principal.set(security.Principal(payload.userId,'passenger'))
    try:
        with pytest.raises(HTTPException) as e:service.create(payload,'cloud-test-forgery-key')
        assert e.value.status_code in {403,503}
        assert memory.get('/rideRequests') is None
    finally:security.current_principal.reset(token)


def test_staging_storage_does_not_use_memory(environment):
    memory=FirebaseClient(FirebaseSettings(None,None,None,None,True,require_real_storage=True))
    with pytest.raises(HTTPException) as e:memory.set('/rideRequests/test',{})
    assert e.value.status_code==503 and memory._memory_db.get('/rideRequests') is None


def test_immutable_bootstrap_records_refuse_overwrite():
    memory=FirebaseClient(FirebaseSettings(None,None,None,None,True))
    cli._create_once(memory,'/cloudTestRuns/trial',{'ready':True})
    with pytest.raises(ValueError):cli._create_once(memory,'/cloudTestRuns/trial',{'ready':False})
    assert memory.get('/cloudTestRuns/trial')=={'ready':True}


def test_http_health_marker_and_vision_remain_ineligible(environment):
    previous=dict(app.dependency_overrides)
    app.dependency_overrides[security.get_principal]=lambda:security.Principal('test-admin','admin')
    try:
        with TestClient(app) as client:
            health=client.get('/health').json()
            assert health['cloudTestProjectId']=='mobi-cloud-test'
            assert client.post('/firebase/initialize',json={'reset':True}).status_code==403
            assert client.get('/ai-vision/v2/sessions/not-active/observations').status_code==503
    finally:
        app.dependency_overrides.clear();app.dependency_overrides.update(previous)


def lifecycle_double(config,tmp_path):
    from scripts.cloud_test_lifecycle import Lifecycle
    from firebase_admin import auth
    users={};calls=[]
    class LocalAuth:
        def get_user(self,uid):
            if uid not in users:raise auth.UserNotFoundError('absent')
            return users[uid]
        def get_user_by_email(self,email):
            for user in users.values():
                if user.email==email:return user
            raise auth.UserNotFoundError('absent')
        def create_user(self,**value):
            calls.append(value['uid'])
            users[value['uid']]=SimpleNamespace(uid=value['uid'],email=value['email'],display_name=value['display_name'],disabled=False,custom_claims=None,user_metadata=SimpleNamespace(creation_timestamp=123456))
            return users[value['uid']]
        def set_custom_user_claims(self,uid,claims):users[uid].custom_claims=claims
        def delete_user(self,uid):del users[uid]
    memory=FirebaseClient(FirebaseSettings(None,None,None,None,True))
    runner=Lifecycle(cli,config,'legacy-regression',tmp_path/'execution.json',auth_client=LocalAuth(),storage=memory)
    return runner,users,calls,memory


def test_bootstrap_exact_scope_recovery_and_no_unrelated_adoption(environment,tmp_path):
    runner,users,calls,memory=lifecycle_double(environment,tmp_path)
    assert runner.run('auth-bootstrap','unique-test-password-for-run')['accounts']==4
    assert runner.run('auth-bootstrap','unique-test-password-for-run')['accounts']==4
    runner.run('rtdb-bootstrap');runner.run('rtdb-bootstrap')
    assert len(calls)==4
    assert memory.get(cloud_test.validate().path)['state']=='ready'
    users[cloud_test.validate().uid('driver-a')].display_name='unrelated account'
    with pytest.raises(ValueError):runner.run('auth-bootstrap','unique-test-password-for-run')
    assert len(calls)==4


def test_bootstrap_failure_does_not_publish_ready(environment,tmp_path):
    runner,users,calls,memory=lifecycle_double(environment,tmp_path)
    def failed(*args):raise RuntimeError('provider-secret-must-not-escape')
    runner.auth.set_custom_user_claims=failed
    with pytest.raises(RuntimeError):runner.run('auth-bootstrap','unique-test-password-for-run')
    assert memory.get(cloud_test.validate().path) is None
    assert json.loads(runner.journal.path.read_text())['accounts']


def test_provider_error_is_sanitized_at_cli_boundary(tmp_path,monkeypatch,capsys):
    path=tmp_path/'public.json';path.write_text(json.dumps(config()))
    def failed(*a):raise ValueError('provider-secret-must-not-escape')
    monkeypatch.setattr(cli,'bootstrap',failed)
    monkeypatch.setenv('MOBI_CLOUD_TEST_PASSWORD','unique-test-password-for-run')
    assert cli.main(['bootstrap','--config',str(path),'--apply','--approved-project-id','mobi-cloud-test',
                     '--approved-run-id','trial-20261019-a'])==1
    output=capsys.readouterr()
    assert 'provider-secret' not in output.err+output.out


@pytest.mark.parametrize('name,claims',[
    ('driver-a',{'mobi_role':'driver','mobi_driver_id':'other-driver'}),
    ('passenger-a',{'mobi_role':'admin'}),
])
def test_misprovisioned_roles_and_driver_mapping_rejected(environment,name,claims):
    scope=cloud_test.validate()
    assert not cloud_test.account_allowed(scope.uid(name),{**claims,'mobi_cloud_test_run':scope.run_id},scope)


def test_cloud_test_admin_cannot_use_out_of_scope_mutations(environment):
    previous=dict(app.dependency_overrides)
    app.dependency_overrides[security.get_principal]=lambda:security.Principal('test-admin','admin')
    try:
        with TestClient(app) as client:
            assert client.post('/safety-events',json={}).status_code==403
            assert client.post('/notifications/send',json={}).status_code==403
    finally:
        app.dependency_overrides.clear();app.dependency_overrides.update(previous)


def test_write_probe_denied_in_cloud_test(environment):
    memory=FirebaseClient(FirebaseSettings(None,None,None,None,True))
    with pytest.raises(HTTPException) as e:memory.probe()
    assert e.value.status_code==403 and memory._memory_db.get('mobiHealthCheck') is None


@pytest.mark.parametrize('operation',['get','set','update','push','delete','transaction'])
def test_cloud_storage_transport_failure_is_sanitized_503(environment,monkeypatch,operation):
    scope=cloud_test.validate()
    client=FirebaseClient(FirebaseSettings(scope.project_id,scope.database_url,None,None,False,True,True))
    monkeypatch.setattr(client,'_use_memory',lambda:False)
    def fail(*a):raise RuntimeError('secret-provider-detail')
    monkeypatch.setattr(client,'_real_reference',lambda p:SimpleNamespace(**{operation:fail}))
    args=('/test',) if operation in {'get','delete'} else ('/test',lambda raw:raw) if operation=='transaction' else ('/test',{})
    with pytest.raises(HTTPException) as e:getattr(client,operation)(*args)
    assert e.value.status_code==503 and 'secret' not in str(e.value.detail)
    assert client._memory_db.get('/test') is None


def test_cloud_admin_cannot_create_or_read_foreign_run_request(environment):
    scope,memory,service,payload=dispatch(environment)
    token=security.current_principal.set(security.Principal(scope.uid('admin'),'admin'))
    try:
        with pytest.raises(HTTPException):service.create(payload.model_copy(update={'userId':'other-user'}),'cloud-test-foreign-key')
        memory.set('/rideRequests/foreign',{'userId':'other-user','targetDriverId':'other-driver',
            'stopId':'s','routeId':'r','busNo':'502','status':'WAITING','createdAt':'2026-01-01T00:00:00+00:00'})
        with pytest.raises(HTTPException) as e:service.get('foreign')
        assert e.value.status_code==403
        with pytest.raises(HTTPException):service.list_by_driver('other-driver')
    finally:security.current_principal.reset(token)


def test_real_transaction_keeps_business_conflict_status(environment,monkeypatch):
    scope=cloud_test.validate()
    client=FirebaseClient(FirebaseSettings(scope.project_id,scope.database_url,None,None,False,True,True))
    monkeypatch.setattr(client,'_use_memory',lambda:False)
    def commit(transform):return transform({'status':'CANCELLED'})
    monkeypatch.setattr(client,'_real_reference',lambda p:SimpleNamespace(transaction=commit))
    def conflict(raw):raise HTTPException(409,'Existing business conflict')
    with pytest.raises(HTTPException) as e:client.transaction('/test',conflict)
    assert e.value.status_code==409


def main_config():
    c=config();project='mobi-smart-transport'
    c.update(projectId=project,databaseUrl=f'https://{project}-default-rtdb.asia-southeast1.firebasedatabase.app',mainProjectTest=True)
    for name in ('passenger','driver'):
        c[name]['MOBI_FIREBASE_PROJECT_ID']=project
        c[name]['MOBI_FIREBASE_AUTH_DOMAIN']=project+'.firebaseapp.com'
        c[name]['MOBI_FIREBASE_APP_ID']=cloud_test.MAIN_WEB_APP_IDS[name]
        c[name]['MOBI_FIREBASE_MESSAGING_SENDER_ID']='882602390759'
    return c


@pytest.fixture
def main_environment(environment,monkeypatch):
    c=main_config()
    for key,value in cli.environment_for(c).items():monkeypatch.setenv(key,value)
    return c


def test_main_project_requires_exact_additional_opt_in(environment,monkeypatch):
    c=main_config()
    for key,value in cli.environment_for(c).items():monkeypatch.setenv(key,value)
    assert cloud_test.validate().main_project_test
    monkeypatch.delenv('MOBI_CLOUD_TEST_MAIN_PROJECT')
    with pytest.raises(ValueError):cloud_test.validate()


@pytest.mark.parametrize('target',['another-main','mobi-smart-transport-cloud','mobi-cloud-test'])
def test_main_opt_in_does_not_allow_other_projects(main_environment,monkeypatch,target):
    monkeypatch.setenv('MOBI_CLOUD_TEST_PROJECT_ID',target)
    with pytest.raises(ValueError):cloud_test.validate()


def test_main_offline_plan_names_only_isolated_database_paths(main_environment,tmp_path,monkeypatch,capsys):
    path=tmp_path/'public.json';path.write_text(json.dumps(main_environment))
    monkeypatch.setattr(cli,'bootstrap',lambda *a:pytest.fail('unexpected cloud write'))
    assert cli.main(['bootstrap','--config',str(path)])==0
    result=json.loads(capsys.readouterr().out)
    scope=cloud_test.validate()
    assert result['mainProjectTest'] and not result['networkPerformed']
    assert all(p.startswith(scope.path+'/') for p in result['bootstrapDatabasePaths']+result['smokeDatabasePaths'])
    assert scope.path+'/manifest' in result['bootstrapDatabasePaths']
    assert len(result['authAccounts'])==4
    assert result['createsGlobalAdmin'] is False


def test_main_apply_needs_additional_flag(main_environment,tmp_path,monkeypatch,capsys):
    from scripts import cloud_test_lifecycle
    path=tmp_path/'public.json';path.write_text(json.dumps(main_environment))
    calls=[]
    class Stage:
        def __init__(self,*args):pass
        def run(self,*args):calls.append('approved');return {'status':'PASS'}
    monkeypatch.setattr(cloud_test_lifecycle,'Lifecycle',Stage)
    monkeypatch.setattr(cli,'validate_stage_credential',lambda *args:None)
    case='main-stage-test'
    args=['auth-bootstrap','--config',str(path),'--case-id',case,'--journal',str(tmp_path/'run.json'),
          '--apply','--approved-project-id','mobi-smart-transport','--approved-run-id',main_environment['runId'],
          '--approved-stage','auth-bootstrap','--approved-plan-sha256',cli.execution_plan(main_environment,case)['planSha256']]
    assert cli.main(args)==1 and not calls
    assert '--allow-main-project-test' in capsys.readouterr().err
    monkeypatch.setenv('MOBI_CLOUD_TEST_PASSWORD','unique-test-password-for-run')
    assert cli.main(args+['--allow-main-project-test'])==0 and calls==['approved']


@pytest.mark.parametrize('path',['/','/../drivers','/drivers/../foreign','/drivers//foreign',
                                '/cloudTestRuns/other-run','/cloudTestRuns/trial-20261019-a/data',
                                '/drivers/a.b','/drivers/a\\b','/drivers/a#b'])
def test_main_storage_path_rejects_escape_and_foreign_run(main_environment,path):
    with pytest.raises(ValueError):cloud_test.validate().storage_path(path)


@pytest.mark.parametrize('operation',['get','set','update','push','delete','transaction'])
def test_all_real_sdk_operations_use_main_run_namespace(main_environment,monkeypatch,operation):
    scope=cloud_test.validate();seen=[]
    client=FirebaseClient(FirebaseSettings(scope.project_id,scope.database_url,None,None,False,True,True))
    client._initialized=True;client._using_mock=False
    def reference(path):
        seen.append(path)
        return SimpleNamespace(get=lambda:None,set=lambda value:None,update=lambda value:None,
            push=lambda value:SimpleNamespace(key='synthetic-key'),delete=lambda:None,
            transaction=lambda transform:transform(None))
    client._db_module=SimpleNamespace(reference=reference)
    args=('/rideRequests/test',) if operation in {'get','delete'} else (
         '/rideRequests/test',lambda raw:{'status':'WAITING'}) if operation=='transaction' else ('/rideRequests/test',{'status':'WAITING'})
    getattr(client,operation)(*args)
    assert seen==[scope.path+'/data/rideRequests/test']
    assert client.get(scope.path) is None and seen[-1]==scope.path+'/manifest'


def test_main_transaction_rechecks_storage_target(main_environment,monkeypatch):
    scope=cloud_test.validate()
    client=FirebaseClient(FirebaseSettings('other-project',scope.database_url,None,None,False,True,True))
    client._initialized=True;client._using_mock=False
    client._db_module=SimpleNamespace(reference=lambda p:pytest.fail('wrong project contacted'))
    with pytest.raises(HTTPException) as e:client.transaction('/rideRequests/test',lambda raw:raw)
    assert e.value.status_code==503


@pytest.mark.parametrize('key',['/drivers/foreign','../foreign','ok/../../foreign','cloudTestRuns/../foreign'])
def test_main_multi_location_update_cannot_escape(main_environment,key):
    scope=cloud_test.validate()
    client=FirebaseClient(FirebaseSettings(scope.project_id,scope.database_url,None,None,False,True,True))
    client._initialized=True;client._using_mock=False
    client._db_module=SimpleNamespace(reference=lambda p:pytest.fail('invalid update reached SDK'))
    with pytest.raises((ValueError,HTTPException)):client.update('/drivers', {key:'invalid'})


def test_dedicated_project_uses_same_run_mapping(environment):
    scope=cloud_test.validate()
    assert not scope.main_project_test and scope.storage_path('/drivers/test')==scope.path+'/data/drivers/test'


def test_main_run_roles_remain_exact(main_environment):
    scope=cloud_test.validate()
    assert cloud_test.account_allowed(scope.uid('passenger-a'),{'mobi_role':'passenger','mobi_cloud_test_run':scope.run_id},scope)
    assert not cloud_test.account_allowed('existing-main-user',{'mobi_role':'admin','mobi_cloud_test_run':scope.run_id},scope)
    assert not cloud_test.account_allowed(scope.uid('passenger-a'),{'mobi_role':'vision_producer','mobi_cloud_test_run':scope.run_id},scope)


def test_main_run_namespaces_are_disjoint(main_environment):
    a=cloud_test.validate()
    b=cloud_test.CloudTestScope(a.project_id,a.database_url,'trial-20261020-other',True)
    assert a.storage_path('/drivers/test')!=b.storage_path('/drivers/test')
    assert a.uid('passenger-a')!=b.uid('passenger-a')


def test_main_http_seed_and_vision_stay_disabled(main_environment,monkeypatch):
    # Model a separate process importing the app after staging configuration.
    from app import main as backend_main
    monkeypatch.setattr(backend_main,'APP_ENV','staging')
    previous=dict(app.dependency_overrides)
    app.dependency_overrides[security.get_principal]=lambda:security.Principal('test-admin','admin')
    try:
        with TestClient(app) as client:
            h=client.get('/health').json()
            assert h['cloudTestProjectId']=='mobi-smart-transport' and h['environment']=='staging'
            assert client.post('/firebase/initialize',json={'reset':True}).status_code==403
            assert client.post('/safety-events',json={}).status_code==403
            assert client.get('/ai-vision/v2/sessions/not-active/observations').status_code==503
    finally:
        app.dependency_overrides.clear();app.dependency_overrides.update(previous)



def test_main_admin_and_elevated_normal_accounts_are_not_allowed(main_environment):
    scope=cloud_test.validate()
    for name in (*cli.NAMES,'admin'):
        assert not cloud_test.account_allowed(scope.uid(name),{'mobi_role':'admin','mobi_cloud_test_run':scope.run_id},scope)
    accounts,_,_=cli.fixture(main_environment)
    assert len(accounts)==4
    assert {a['claims']['mobi_role'] for a in accounts}=={'passenger','driver'}


def test_main_bootstrap_blocked_without_atomic_claims_ownership(main_environment,tmp_path):
    runner,users,calls,memory=lifecycle_double(main_environment,tmp_path)
    with pytest.raises(ValueError,match='atomic'):
        runner.run('auth-bootstrap','unique-test-password-for-run')
    assert not users and not calls


def test_main_bootstrap_injected_admin_rejected_before_sdk(main_environment,tmp_path,monkeypatch):
    from scripts.cloud_test_lifecycle import Lifecycle
    accounts,drivers,manifest=cli.fixture(main_environment)
    accounts[0]['claims']['mobi_role']='admin'
    monkeypatch.setattr(cli,'fixture',lambda c:(accounts,drivers,manifest))
    monkeypatch.setattr(security,'firebase_auth_app',lambda:pytest.fail('SDK initialized for an unsafe account plan'))
    with pytest.raises(ValueError,match='admin is forbidden'):
        Lifecycle(cli,main_environment,'unsafe-test',tmp_path/'execution.json')


@pytest.mark.parametrize('bad_case',['partial-driver','swapped-apps','wrong-sender','wrong-project'])
def test_main_build_inputs_fail_closed(tmp_path,bad_case):
    c=main_config()
    if bad_case=='partial-driver':c['driver']['MOBI_FIREBASE_APP_ID']='1:882602390759:web'
    if bad_case=='swapped-apps':c['passenger'],c['driver']=c['driver'],c['passenger']
    if bad_case=='wrong-sender':c['driver']['MOBI_FIREBASE_MESSAGING_SENDER_ID']='other-project-number'
    if bad_case=='wrong-project':c['driver']['MOBI_FIREBASE_PROJECT_ID']='other-cloud-test'
    path=tmp_path/'public.json';path.write_text(json.dumps(c))
    with pytest.raises(ValueError):cli.load_config(path)


def test_main_confirmed_web_config_prepare_and_plan_are_offline(tmp_path,monkeypatch):
    c=main_config();c['databaseUrl']=cloud_test.MAIN_DATABASE_URL
    path=tmp_path/'public.json';path.write_text(json.dumps(c))
    config=cli.load_config(path);output=tmp_path/'prepared'
    cli.prepare(config,output)
    for name in ('passenger','driver'):
        data=json.loads((output/f'{name}-defines.json').read_text())
        assert data['MOBI_FIREBASE_APP_ID']==cloud_test.MAIN_WEB_APP_IDS[name]
        assert data['MOBI_FIREBASE_PROJECT_ID']=='mobi-smart-transport'
        assert data['MOBI_LOCAL_DEMO']=='false'
        assert data['MOBI_API_BASE_URL']=='http://127.0.0.1:8011'
        assert set(data)==cli.PUBLIC_KEYS|{'MOBI_LOCAL_DEMO','MOBI_API_BASE_URL'}
    plan=json.loads((output/'cloud-test-plan.json').read_text())
    assert not plan['networkPerformed'] and not plan['createsGlobalAdmin']
    assert len(plan['authAccounts'])==4 and plan['deferredAdminChecks']


def test_main_rejects_different_database_region(main_environment,monkeypatch):
    url='https://mobi-smart-transport-default-rtdb.firebaseio.com'
    monkeypatch.setenv('FIREBASE_DATABASE_URL',url)
    monkeypatch.setenv('MOBI_CLOUD_TEST_DATABASE_URL',url)
    with pytest.raises(ValueError,match='Singapore'):cloud_test.validate()


def test_four_account_http_workflow_and_admin_denial(main_environment,monkeypatch):
    from app.api.routes import ride_requests
    scope,memory,service,payload=dispatch(main_environment)
    monkeypatch.setattr(ride_requests,'_service',service)
    accounts,_,_=cli.fixture(main_environment)
    claims={a['uid']:a['claims'] for a in accounts}
    claims[scope.uid('admin')]={'mobi_role':'admin','mobi_cloud_test_run':scope.run_id}
    monkeypatch.setattr(security,'firebase_auth_app',lambda:object())
    monkeypatch.setattr(security.auth,'verify_id_token',lambda token,**kwargs:{'uid':token,'exp':time.time()+300})
    monkeypatch.setattr(security.auth,'get_user',lambda uid,**kwargs:SimpleNamespace(disabled=False,custom_claims=claims[uid]))
    previous=dict(app.dependency_overrides);app.dependency_overrides.clear()
    try:
        with TestClient(app) as client:
            def call(method,path,name,**kwargs):
                return client.request(method,path,headers={'Authorization':'Bearer '+scope.uid(name)},**kwargs)
            # Even a correctly signed token/current global admin claim is excluded.
            assert call('GET','/firebase/status','admin').status_code==403
            for name in cli.NAMES:
                assert call('POST','/firebase/initialize',name,json={'reset':True}).status_code==403
            r=call('POST','/ride-requests','passenger-a',json=payload.model_dump(mode='json'))
            assert r.status_code==200,r.text
            path='/ride-requests/'+r.json()['requestId']
            assert call('GET',path,'passenger-b').status_code==403
            assert call('PATCH',path+'/status','driver-b',json={'status':'ACCEPTED'}).status_code==403
            assert call('PATCH',path+'/status','driver-a',json={'status':'ACCEPTED'}).status_code==200
            assert call('PATCH',path+'/status','passenger-a',json={'status':'CANCELLED'}).status_code==200
            claims[scope.uid('passenger-a')]['mobi_role']='admin'
            assert call('GET',path,'passenger-a').status_code==403
    finally:
        app.dependency_overrides.clear();app.dependency_overrides.update(previous)


# MEDIUM review regressions. Product code must reject these before ADC/network.
@pytest.mark.parametrize('kind', ['main-passenger','main-driver','main-sender','swapped','unconfirmed','api-key-mismatch'])
def test_medium_untrusted_web_registration_rejected(environment,monkeypatch,tmp_path,kind):
    from copy import deepcopy
    c=deepcopy(environment)
    trusted={c['projectId']:{k:deepcopy(c[k]) for k in ('projectId','databaseUrl','passenger','driver')}}
    monkeypatch.setattr(cloud_test,'CONFIRMED_TEST_PROJECTS',trusted,raising=False)
    if kind=='main-passenger':
        c['passenger']['MOBI_FIREBASE_APP_ID']=cloud_test.MAIN_WEB_APP_IDS['passenger']
        c['passenger']['MOBI_FIREBASE_MESSAGING_SENDER_ID']='882602390759'
    elif kind=='main-driver':
        c['driver']['MOBI_FIREBASE_APP_ID']=cloud_test.MAIN_WEB_APP_IDS['driver']
        c['driver']['MOBI_FIREBASE_MESSAGING_SENDER_ID']='882602390759'
    elif kind=='main-sender':
        c['passenger']['MOBI_FIREBASE_APP_ID']='1:882602390759:web:'+'d'*24
        c['passenger']['MOBI_FIREBASE_MESSAGING_SENDER_ID']='882602390759'
    elif kind=='swapped':c['passenger'],c['driver']=c['driver'],c['passenger']
    elif kind=='unconfirmed':monkeypatch.setattr(cloud_test,'CONFIRMED_TEST_PROJECTS',{})
    else:c['passenger']['MOBI_FIREBASE_API_KEY']='different-project-public-key'
    path=tmp_path/'public.json';path.write_text(json.dumps(c))
    with pytest.raises(ValueError):cli.load_config(path)


@pytest.mark.parametrize('logical',['/drivers/one','/rideRequests/one','/v3GuidanceSessions/v3-'+'a'*32])
def test_medium_dedicated_paths_are_run_scoped(environment,logical):
    scope=cloud_test.validate()
    assert scope.storage_path(logical)==scope.path+'/data'+logical
    assert scope.storage_path(scope.path)==scope.path+'/manifest'


@pytest.mark.parametrize('logical',['/','/cloudTestRuns/another-run','/drivers/../foreign',
                                    '/drivers/a.b','/drivers//foreign','/cloudTestRuns/'+ 'trial-20261019-a'+'/data/drivers/a'])
def test_medium_dedicated_path_escape_rejected(environment,logical):
    with pytest.raises(ValueError):cloud_test.validate().storage_path(logical)


@pytest.mark.parametrize('logical',['/drivers/one','/rideRequests/one','/v3GuidanceSessions/v3-'+'a'*32])
@pytest.mark.parametrize('operation',['get','set','update','push','delete','transaction'])
def test_medium_real_sdk_operations_use_dedicated_namespace(environment,logical,operation):
    scope=cloud_test.validate();seen=[]
    client=FirebaseClient(FirebaseSettings(scope.project_id,scope.database_url,None,None,False,True,True))
    client._initialized=True;client._using_mock=False
    def reference(path):
        seen.append(path)
        return SimpleNamespace(get=lambda:{},set=lambda value:None,update=lambda value:None,
            push=lambda value:SimpleNamespace(key='synthetic-key'),delete=lambda:None,
            transaction=lambda transform:transform(None))
    client._db_module=SimpleNamespace(reference=reference)
    args=(logical,) if operation in {'get','delete'} else (
        logical,lambda raw:{'status':'WAITING'}) if operation=='transaction' else (logical,{'status':'WAITING'})
    getattr(client,operation)(*args)
    assert seen==[scope.path+'/data'+logical]


@pytest.mark.parametrize('key',['/drivers/foreign','../foreign','ok/../../foreign','cloudTestRuns/../foreign'])
def test_medium_dedicated_multilocation_escape_rejected(environment,key):
    scope=cloud_test.validate()
    client=FirebaseClient(FirebaseSettings(scope.project_id,scope.database_url,None,None,False,True,True))
    client._initialized=True;client._using_mock=False
    client._db_module=SimpleNamespace(reference=lambda p:pytest.fail('Invalid key reached SDK'))
    with pytest.raises((ValueError,HTTPException)):client.update('/drivers',{key:'invalid'})


def test_medium_unconfirmed_project_blocked_at_runtime(environment,monkeypatch):
    monkeypatch.setattr(cloud_test,'CONFIRMED_TEST_PROJECTS',{})
    with pytest.raises(ValueError,match='unconfirmed'):cloud_test.validate()
    with pytest.raises(ValueError,match='unconfirmed'):cli.configure(environment)


def test_medium_config_cannot_self_certify_registration(environment,monkeypatch,tmp_path):
    monkeypatch.setattr(cloud_test,'CONFIRMED_TEST_PROJECTS',{})
    c=dict(environment,confirmedRegistration={'verified':True,'projectId':environment['projectId']})
    path=tmp_path/'public.json';path.write_text(json.dumps(c))
    with pytest.raises(ValueError):cli.load_config(path)


def test_medium_mismatched_registered_database_is_rejected(environment,monkeypatch):
    from copy import deepcopy
    c=deepcopy(environment)
    c['databaseUrl']='https://mobi-cloud-test-default-rtdb.asia-southeast1.firebasedatabase.app'
    monkeypatch.setenv('FIREBASE_DATABASE_URL',c['databaseUrl'])
    monkeypatch.setenv('MOBI_CLOUD_TEST_DATABASE_URL',c['databaseUrl'])
    with pytest.raises(ValueError,match='reviewed'):cloud_test.validate()


def test_medium_sender_mismatch_and_incomplete_driver_rejected(environment,tmp_path):
    from copy import deepcopy
    for key,value in [('MOBI_FIREBASE_MESSAGING_SENDER_ID','999'),
                      ('MOBI_FIREBASE_APP_ID','1:882602390759:web')]:
        c=deepcopy(environment);c['driver'][key]=value
        path=tmp_path/'public.json';path.write_text(json.dumps(c))
        with pytest.raises(ValueError):cli.load_config(path)


def test_medium_web_settings_bound_to_plan_hash(environment):
    from copy import deepcopy
    a=cli.execution_plan(environment,'plan-hash-test')
    c=deepcopy(environment);c['passenger']['MOBI_FIREBASE_API_KEY']='changed-public-key'
    b=cli.execution_plan(c,'plan-hash-test')
    assert a['planSha256']!=b['planSha256']
    assert a['webRegistrationSha256']!=b['webRegistrationSha256']


def test_medium_unregistered_cli_stops_before_credentials(environment,tmp_path,monkeypatch,capsys):
    monkeypatch.setattr(cloud_test,'CONFIRMED_TEST_PROJECTS',{})
    monkeypatch.setattr(cli,'validate_stage_credential',lambda *args:pytest.fail('ADC access for unknown project'))
    path=tmp_path/'public.json';path.write_text(json.dumps(environment))
    assert cli.main(['auth-bootstrap','--config',str(path),'--apply'])==1
    assert 'unconfirmed' in capsys.readouterr().err


def test_medium_dedicated_runs_and_manifest_are_disjoint(environment):
    a=cloud_test.validate()
    b=cloud_test.CloudTestScope(a.project_id,a.database_url,'other-20261023-run',False)
    assert a.storage_path('/drivers/a')!=b.storage_path('/drivers/a')
    assert a.storage_path(a.path)==a.path+'/manifest'
    assert b.storage_path(b.path)==b.path+'/manifest'
    plan=cli.execution_plan(environment,'path-plan-test')
    assert plan['databaseRoot']==a.path
    assert all(p.startswith(a.path+'/') for p in plan['bootstrapDatabasePaths']+plan['smokeDatabasePaths'])


@pytest.fixture
def registered_test_config(environment,monkeypatch):
    from copy import deepcopy
    monkeypatch.setattr(cloud_test,'CONFIRMED_TEST_PROJECTS',_CONSOLE_REGISTRATIONS)
    c=deepcopy(_CONSOLE_REGISTRATIONS['mobi-auth-cloud-test'])
    c.update(runId='offline-20261023-a',mainProjectTest=False,
             backendPort=8011,passengerPort=5183,driverPort=5184)
    for key,value in cli.environment_for(c).items():monkeypatch.setenv(key,value)
    return c


def test_console_supplied_registration_exact_roles(registered_test_config,tmp_path):
    c=registered_test_config
    assert c['passenger']['MOBI_FIREBASE_APP_ID']=='1:189730626159:web:407d25db8c026703170b9a'
    assert c['driver']['MOBI_FIREBASE_APP_ID']=='1:189730626159:web:b486ec4c18abf663170b9a'
    for name in ('passenger','driver'):
        assert c[name]['MOBI_FIREBASE_MESSAGING_SENDER_ID']=='189730626159'
        assert c[name]['MOBI_FIREBASE_PROJECT_ID']=='mobi-auth-cloud-test'
        cloud_test.validate_web_app(c[name],name,c['projectId'])
    import hashlib
    assert hashlib.sha256(c['passenger']['MOBI_FIREBASE_API_KEY'].encode()).hexdigest()=='468d2330321093a099e56f2c7b7f50618e14ce4d463d36a59499eb74826e2888'
    assert c['passenger']['MOBI_FIREBASE_API_KEY']==c['driver']['MOBI_FIREBASE_API_KEY']
    path=tmp_path/'public.json';path.write_text(json.dumps(c))
    assert cli.load_config(path)==c
    assert cloud_test.validate().database_url==c['databaseUrl']


@pytest.mark.parametrize('kind',['main-passenger','main-driver','main-sender','swap','truncated-driver',
                                'sender-mismatch','api-key','project','database','unregistered'])
def test_console_registration_mixing_denied(registered_test_config,tmp_path,kind):
    from copy import deepcopy
    c=deepcopy(registered_test_config)
    if kind in {'main-passenger','main-driver'}:
        role=kind.split('-')[1]
        c[role]['MOBI_FIREBASE_APP_ID']=cloud_test.MAIN_WEB_APP_IDS[role]
        c[role]['MOBI_FIREBASE_MESSAGING_SENDER_ID']=cloud_test.MAIN_SENDER_ID
    elif kind=='main-sender':c['driver']['MOBI_FIREBASE_MESSAGING_SENDER_ID']=cloud_test.MAIN_SENDER_ID
    elif kind=='swap':c['passenger'],c['driver']=c['driver'],c['passenger']
    elif kind=='truncated-driver':c['driver']['MOBI_FIREBASE_APP_ID']='1:189730626159:web'
    elif kind=='sender-mismatch':c['passenger']['MOBI_FIREBASE_MESSAGING_SENDER_ID']='999'
    elif kind=='api-key':c['passenger']['MOBI_FIREBASE_API_KEY']='other-project-public-key'
    elif kind=='project':c['driver']['MOBI_FIREBASE_PROJECT_ID']='mobi-smart-transport'
    elif kind=='database':c['databaseUrl']=cloud_test.MAIN_DATABASE_URL
    else:
        c['projectId']='mobi-unknown-cloud-test'
        c['databaseUrl']='https://mobi-unknown-cloud-test-default-rtdb.firebaseio.com'
        for role in ('passenger','driver'):
            c[role]['MOBI_FIREBASE_PROJECT_ID']=c['projectId']
            c[role]['MOBI_FIREBASE_AUTH_DOMAIN']=c['projectId']+'.firebaseapp.com'
    path=tmp_path/'public.json';path.write_text(json.dumps(c))
    with pytest.raises(ValueError):cli.load_config(path)


def test_console_registration_offline_preflight_no_adc_or_network(registered_test_config,tmp_path,monkeypatch,capsys):
    def forbidden(*args,**kwargs):pytest.fail('Offline preflight attempted credentials/network')
    import google.auth,httpx,requests
    monkeypatch.setattr(google.auth,'default',forbidden)
    monkeypatch.setattr(requests.Session,'request',forbidden)
    monkeypatch.setattr(httpx.Client,'request',forbidden)
    monkeypatch.setattr(security,'firebase_auth_app',forbidden)
    monkeypatch.setattr(cli,'validate_stage_credential',forbidden)
    c=registered_test_config;path=tmp_path/'public.json';path.write_text(json.dumps(c))
    assert cli.main(['preflight','--config',str(path),'--case-id','offline-check'])==0
    result=json.loads(capsys.readouterr().out)
    assert result['networkPerformed'] is False and result['projectId']=='mobi-auth-cloud-test'
    assert result['createsGlobalAdmin'] is False and result['authAutomaticDeletion'] is False
    assert result['databaseRoot']=='/cloudTestRuns/'+c['runId']


def test_console_registration_flutter_defines_and_paths(registered_test_config,tmp_path):
    c=registered_test_config;output=tmp_path/'defines'
    cli.prepare(c,output)
    for name in ('passenger','driver'):
        defines=json.loads((output/(name+'-defines.json')).read_text())
        assert all(defines[key]==value for key,value in c[name].items())
        assert defines['MOBI_LOCAL_DEMO']=='false'
        assert defines['MOBI_API_BASE_URL']=='http://127.0.0.1:8011'
    scope=cloud_test.validate()
    for path in ('/drivers/one','/rideRequests/one','/v3GuidanceSessions/one'):
        assert scope.storage_path(path)==scope.path+'/data'+path


def test_console_registration_apply_without_adc_is_denied(registered_test_config,tmp_path,monkeypatch,capsys):
    c=registered_test_config;path=tmp_path/'public.json';path.write_text(json.dumps(c))
    monkeypatch.delenv('GOOGLE_APPLICATION_CREDENTIALS',raising=False)
    monkeypatch.delenv('FIREBASE_SERVICE_ACCOUNT_PATH',raising=False)
    monkeypatch.setattr(security,'firebase_auth_app',lambda:pytest.fail('Unexpected SDK init'))
    case='offline-deny';plan=cli.execution_plan(c,case)
    args=['preflight','--config',str(path),'--case-id',case,'--journal',str(tmp_path/'execution.json'),
          '--apply','--approved-project-id',c['projectId'],'--approved-run-id',c['runId'],
          '--approved-stage','preflight','--approved-plan-sha256',plan['planSha256']]
    assert cli.main(args)==1
    assert 'explicit keyless' in capsys.readouterr().err
    assert not (tmp_path/'execution.json').exists()
