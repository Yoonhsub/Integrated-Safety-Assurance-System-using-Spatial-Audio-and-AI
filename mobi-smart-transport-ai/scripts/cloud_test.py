"""Local FastAPI / isolated real Firebase test tools. Default: plan, no network."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend/api'))
sys.path.insert(0, str(ROOT))
from app.cloud_test import validate, validate_web_app, account_allowed, CloudTestConfigurationError, CloudTestScope, ensure_execution_run

PUBLIC_KEYS = {'MOBI_FIREBASE_API_KEY','MOBI_FIREBASE_APP_ID','MOBI_FIREBASE_MESSAGING_SENDER_ID',
               'MOBI_FIREBASE_PROJECT_ID','MOBI_FIREBASE_AUTH_DOMAIN'}
NAMES = ('passenger-a','passenger-b','driver-a','driver-b')


def load_config(path):
    data=json.loads(Path(path).read_text('utf-8-sig'))
    keys={'projectId','databaseUrl','runId','backendPort','passengerPort','driverPort','passenger','driver'}
    if (not isinstance(data,dict) or set(data) not in (keys, keys | {'mainProjectTest'}, keys | {'authRunId','dataRunId','executionMode'}, keys | {'mainProjectTest','authRunId','dataRunId','executionMode'})
            or type(data.get('mainProjectTest', False)) is not bool):
        raise CloudTestConfigurationError('Cloud-test config must contain only the documented public fields')
    for key in ('projectId','databaseUrl','runId'):
        if not isinstance(data[key],str) or '<' in data[key]:raise CloudTestConfigurationError('Complete public target configuration')
    if 'authRunId' in data and (any(not isinstance(data[k],str) or not data[k] for k in ('authRunId','dataRunId','executionMode')) or data['runId'] != data['dataRunId'] or data['executionMode'] != 'ride-only'):
        raise CloudTestConfigurationError('Explicit dataRunId must match runId in ride-only mode')
    ports=[data[k] for k in ('backendPort','passengerPort','driverPort')]
    if (any(type(p) is not int or not 1024<=p<=65535 or p in {5173,5174,8001,9000,9099} for p in ports)
            or len(set(ports))!=3):raise CloudTestConfigurationError('Use three distinct unoccupied non-demo ports')
    for name in ('passenger','driver'):
        app=data[name]
        if (not isinstance(app,dict) or set(app)!=PUBLIC_KEYS
                or any(not isinstance(v,str) or not v.strip() or '<' in v for v in app.values())
                or app['MOBI_FIREBASE_PROJECT_ID']!=data['projectId']
                or app['MOBI_FIREBASE_AUTH_DOMAIN']!=data['projectId']+'.firebaseapp.com'):
            raise CloudTestConfigurationError('Each registered Web app needs matching public Firebase configuration only')
    for name in ('passenger','driver'):
        validate_web_app(data[name],name,data['projectId'])
    if data['passenger']['MOBI_FIREBASE_APP_ID']==data['driver']['MOBI_FIREBASE_APP_ID']:
        raise CloudTestConfigurationError('Use distinct registered passenger and driver Web apps')
    # Validate without changing the calling process environment or loading .env.
    environment=environment_for(data)
    previous=dict(os.environ)
    try:
        os.environ.clear();os.environ.update(environment);validate()
    finally:
        os.environ.clear();os.environ.update(previous)
    return data


def environment_for(config):
    return {'MOBI_CLOUD_TEST':'1',
        'MOBI_CLOUD_TEST_MAIN_PROJECT':config['projectId'] if config.get('mainProjectTest', False) else '',
        'MOBI_CLOUD_TEST_PROJECT_ID':config['projectId'],
        'MOBI_CLOUD_TEST_AUTH_RUN_ID':config.get('authRunId',''),
        'MOBI_CLOUD_TEST_DATA_RUN_ID':config.get('dataRunId',''),
        'MOBI_CLOUD_TEST_MODE':config.get('executionMode',''),
        'MOBI_CLOUD_TEST_DATABASE_URL':config['databaseUrl'],'MOBI_CLOUD_TEST_RUN_ID':config['runId'],
        'APP_ENV':'staging','FIREBASE_PROJECT_ID':config['projectId'],'GOOGLE_CLOUD_PROJECT':config['projectId'],
        'FIREBASE_DATABASE_URL':config['databaseUrl'],'FIREBASE_USE_ADC':'true','FIREBASE_USE_MOCK':'false',
        'USE_MOCK_DATA':'false','MOBI_LOCAL_DEMO':'0','FIREBASE_SERVICE_ACCOUNT_PATH':'',
        'FIREBASE_AUTH_EMULATOR_HOST':'','FIREBASE_DATABASE_EMULATOR_HOST':'',
        'PUBLIC_DATA_USE_MOCK':'true','FCM_ENABLED':'false','FCM_USE_MOCK':'true',
        'OPENAI_API_KEY':'','GEMINI_API_KEY':'','GOOGLE_API_KEY':'',
        'BACKEND_CORS_ORIGINS':','.join(f'http://127.0.0.1:{config[k]}' for k in ('passengerPort','driverPort'))}


def configure(config):
    ensure_execution_run(config['projectId'], config['runId'],
                         config.get('authRunId',''), config.get('dataRunId',''),
                         config.get('executionMode',''))
    # Never turn an existing emulator/cloud process into cloud-test in-place.
    if (any(os.getenv(k) for k in ('FIREBASE_AUTH_EMULATOR_HOST','FIREBASE_DATABASE_EMULATOR_HOST','K_SERVICE','GAE_ENV'))
            or os.getenv('MOBI_LOCAL_DEMO') in {'1','true'}):
        raise CloudTestConfigurationError('Start cloud-test in a separate clean process, not an emulator/cloud process')
    for name in ('FIREBASE_PROJECT_ID','GOOGLE_CLOUD_PROJECT'):
        if os.getenv(name) not in (None,'',config['projectId']):
            raise CloudTestConfigurationError('Inherited project differs from approved cloud-test project')
    for name in ('passenger','driver'):
        validate_web_app(config[name],name,config['projectId'])
    os.environ.update(environment_for(config));return validate()


def fixture(config):
    run=config['runId'];auth_run=config.get('authRunId',run);uid=lambda n:f'ct-{auth_run}-{n}'
    accounts=[];drivers={};assignments={}
    names=NAMES
    for name in names:
        role='passenger' if name.startswith('passenger') else 'driver' if name.startswith('driver') else 'admin'
        claims={'mobi_role':role,'mobi_cloud_test_run':auth_run}
        if role=='driver':
            bus='502' if name=='driver-a' else '105';driver=uid('driver-'+bus);route='MOCK-'+bus
            claims['mobi_driver_id']=driver
            drivers[driver]={'routeId':route,'busNo':bus,'cloudTestRun':run,'simulation':True}
            assignments[route]={'driverId':driver,'busNo':bus,'simulation':True}
        accounts.append({'uid':uid(name),'email':uid(name)+'@example.test','claims':claims})
    manifest={'version':1,'projectId':config['projectId'],'runId':run,'state':'ready',
                            'purpose':'isolated-cloud-test','assignments':assignments}
    if config.get('executionMode') == 'ride-only':manifest['authRunId']=auth_run
    return accounts,drivers,manifest


def plan(config,case_id):
    ensure_execution_run(config['projectId'], config['runId'],
                         config.get('authRunId',''), config.get('dataRunId',''),
                         config.get('executionMode',''))
    accounts,drivers,run=fixture(config)
    key=f'cloud-test:{config["runId"]}:{case_id}'
    identity=json.dumps([accounts[0]['uid'],key],ensure_ascii=True,separators=(',',':'))
    rid='ride-i-'+hashlib.sha256(identity.encode()).hexdigest()
    from app.cloud_test import CloudTestScope
    scope=CloudTestScope(config['projectId'],config['databaseUrl'],config['runId'],config.get('mainProjectTest',False),config.get('authRunId'),config.get('executionMode')=='ride-only')
    if scope.ride_only and case_id != scope.case_id:
        raise CloudTestConfigurationError('Case differs from the reviewed ride-only action')
    return {'projectId':config['projectId'],'databaseUrl':config['databaseUrl'],'runId':config['runId'],
            'mainProjectTest':scope.main_project_test,
            'databaseRoot':scope.path,
            'networkPerformed':False,'authAccounts':[a['uid'] for a in accounts],
            'createsGlobalAdmin':any(a['claims'].get('mobi_role')=='admin' for a in accounts),
            'deferredAdminChecks':['admin-authenticated legacy seed denial','admin-only status'] if scope.main_project_test else [],
            'accountRoles':[{'uid':a['uid'],**a['claims']} for a in accounts],
            'bootstrapDatabasePaths':[scope.storage_path(scope.path),*[scope.storage_path('/drivers/'+d) for d in drivers]],
            'smokeDatabasePaths':[scope.storage_path('/rideRequests/'+rid)]+([] if scope.ride_only else [scope.storage_path('/v3GuidanceSessions/<server-generated-id>')]),
            'requestId':rid,'idempotencyKey':key,'caseId':case_id,
            'backendOrigin':f'http://127.0.0.1:{config["backendPort"]}',
            'simulation':True,'deletesExistingData':False,'enablesVision':False}


def execution_plan(config,case_id):
    result=plan(config,case_id)
    result['stages']=['preflight','auth-bootstrap','rtdb-bootstrap','backend-smoke','flutter-smoke','cleanup']
    from scripts.cloud_test_lifecycle import exact_accounts
    result['accounts']=exact_accounts(config)
    result['maxAuthAccounts']=4
    result['maxRideRequests']=1
    result['maxGuidanceSessions']=0 if config.get('executionMode')=='ride-only' else 1
    if config.get('executionMode')=='ride-only':
        result.update(authRunId=config['authRunId'],dataRunId=config['dataRunId'],
            authMode='reuse-existing-read-only',newAuthAccounts=0,bootstrapIdentity='Runtime',
            stages=['preflight','auth-reuse-check','rtdb-bootstrap','ride-smoke','cleanup'])
    result['webRegistrationSha256']=hashlib.sha256(json.dumps(
        {key:config[key] for key in ('projectId','databaseUrl','passenger','driver')},
        sort_keys=True,separators=(',',':')).encode()).hexdigest()
    result['authAutomaticDeletion']=False
    result['mainProjectAuthProvisioning']='BLOCKED: no atomic Claims ownership check'
    result['cleanupEvidence']='volatile successful creation receipt; journal alone never authorizes deletion'
    result['sessionCleanup']='manual approval; no request-ID recovery API'

    result['directRtdbProbePath']=CloudTestScope(config['projectId'],config['databaseUrl'],config['runId'],config.get('mainProjectTest',False),config.get('authRunId'),config.get('executionMode')=='ride-only').storage_path('/rideRequests/'+result['requestId'])
    if config.get('executionMode')=='ride-only':
        scope=CloudTestScope(config['projectId'],config['databaseUrl'],config['runId'],False,config['authRunId'],True)
        result.update(
            allowedStorageReads=result['bootstrapDatabasePaths']+result['smokeDatabasePaths']+[scope.storage_path('/rideRequests')],
            allowedStorageMutations=result['bootstrapDatabasePaths']+result['smokeDatabasePaths'],
            fcmTokenReads=0,
            rideCreatePayload={'userId':scope.uid('passenger-a'),'stopId':f'ct-{scope.run_id}-stop-502','routeId':'MOCK-502','busNo':'502'})
    result['planSha256']=hashlib.sha256(json.dumps(result,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest()
    return result


def prepare(config,output):
    output=Path(output).resolve()
    if output.is_relative_to(ROOT.parent) or ROOT.parent.is_relative_to(output) or output.exists():
        raise CloudTestConfigurationError('Choose a fresh output directory outside the repository')
    output.mkdir(parents=True)
    for name in ('passenger','driver'):
        public={**config[name],'MOBI_LOCAL_DEMO':'false',
                'MOBI_API_BASE_URL':f'http://127.0.0.1:{config["backendPort"]}'}
        (output/f'{name}-defines.json').write_text(json.dumps(public,indent=2)+'\n',encoding='utf-8')
    (output/'cloud-test-plan.json').write_text(json.dumps(plan(config,'ride-e2e-01' if config.get('executionMode')=='ride-only' else 'prepare-only'),indent=2)+'\n',encoding='utf-8')


def _create_once(storage,path,value):
    def initialize(raw):
        if raw is not None and raw!=value:raise CloudTestConfigurationError('Existing cloud-test record differs; refusing overwrite')
        return value
    storage.transaction(path,initialize)


def bootstrap(config,password):
    # Combined Auth/RTDB mutation is intentionally retired. Offline plan remains.
    raise CloudTestConfigurationError('Use separately approved auth-bootstrap and rtdb-bootstrap stages with a journal')


def smoke(config,password,case_id,lifecycle=None):
    if lifecycle is None:
        raise CloudTestConfigurationError('backend-smoke requires an approved execution journal')
    scope=configure(config)
    import httpx
    bodyplan=plan(config,case_id);accounts,drivers,_=fixture(config);tokens={};checks=[]
    base=bodyplan['backendOrigin'];run=config['runId']
    def check(ok,label):
        if not ok:raise RuntimeError('Smoke check failed: '+label)
        checks.append(label)
    with httpx.Client(timeout=12,trust_env=False,follow_redirects=False) as c:
        health=c.get(base+'/health');check(health.status_code==200,'backend health')
        h=health.json();check(h.get('environment')=='staging' and h.get('cloudTestProjectId')==config['projectId']
            and h.get('cloudTestRunId')==run and h.get('firebaseMode')=='firebase-admin','exact backend target')
        for account in accounts:
            r=c.post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword',
                params={'key':config['passenger']['MOBI_FIREBASE_API_KEY']},
                json={'email':account['email'],'password':password,'returnSecureToken':True})
            check(r.status_code==200,'real Auth login '+account['uid'].rsplit('-',1)[-1])
            data=r.json();check(data.get('localId')==account['uid'],'Auth UID matches plan')
            tokens[account['uid']]=data['idToken']
            renewal=c.post('https://securetoken.googleapis.com/v1/token',
                params={'key':config['passenger']['MOBI_FIREBASE_API_KEY']},
                data={'grant_type':'refresh_token','refresh_token':data['refreshToken']})
            check(renewal.status_code==200 and renewal.json().get('user_id')==account['uid'],'real token refresh')
            tokens[account['uid']]=renewal.json()['id_token']
        def request(method,path,user=0,**kwargs):
            headers=kwargs.pop('headers',{})
            if user is not None:headers['Authorization']='Bearer '+tokens[accounts[user]['uid']]
            return c.request(method,base+path,headers=headers,**kwargs)
        payload={'userId':accounts[0]['uid'],'stopId':f'ct-{run}-stop-502','routeId':'MOCK-502','busNo':'502'}
        check(request('POST','/ride-requests',None,json=payload).status_code==401,'missing token denied')
        check(c.post(base+'/ride-requests',headers={'Authorization':'Bearer invalid'},json=payload).status_code==401,'invalid token denied')
        check(request('POST','/ride-requests',1,json=payload).status_code==403,'forged passenger denied')
        check(request('POST','/ride-requests',2,json=payload).status_code==403,'driver create denied')
        headers={'Idempotency-Key':bodyplan['idempotencyKey']}
        lifecycle.backend_intent('/rideRequests/'+bodyplan['requestId'])
        if scope.ride_only:
            replies=[request('POST','/ride-requests',json=payload,headers=dict(headers))]
        else:
            with ThreadPoolExecutor(max_workers=2) as pool:
                replies=list(pool.map(lambda _:request('POST','/ride-requests',json=payload,headers=dict(headers)),range(2)))
        check(all(r.status_code==200 for r in replies),'POST accepted' if scope.ride_only else 'concurrent POST accepted')
        records=[r.json() for r in replies];rid=bodyplan['requestId']
        check(all(r['requestId']==rid and r['targetDriverId']==scope.uid('driver-502') for r in records),'one request and server dispatch')
        lifecycle.record_backend_result('/rideRequests/'+rid,records[0])
        path='/ride-requests/'+rid
        check(request('GET',path,1).status_code==403,'foreign passenger denied')
        check(request('PATCH',path+'/status',3,json={'status':'ACCEPTED'}).status_code==403,'wrong driver denied')
        listed=request('GET','/drivers/'+scope.uid('driver-502')+'/ride-requests',2)
        check(listed.status_code==200,'assigned driver list')
        if scope.ride_only:
            check(listed.json()['driverId']==scope.uid('driver-502') and
                  any(row['requestId']==rid for row in listed.json()['requests']),'assigned list contains request')
            check(records[0]['status']=='WAITING','disabled FCM leaves request waiting')
        check(request('POST','/ride-requests',json={**payload,'stopId':'changed'},headers=headers).status_code==409,'same key changed payload conflict')
        r=request('PATCH',path+'/status',2,json={'status':'ACCEPTED'});check(r.status_code==200,'assigned driver accepts')
        lifecycle.record_backend_result('/rideRequests/'+rid,r.json())
        if scope.ride_only:
            current=request('GET',path)
            check(current.status_code==200 and current.json()['status']=='ACCEPTED','owner reads accepted state')
            lifecycle.record_backend_result('/rideRequests/'+rid,current.json())
            check(request('GET',path,3).status_code==403,'unassigned driver read denied')
        r=request('PATCH',path+'/status',0,json={'status':'CANCELLED'});check(r.status_code==200,'owner cancels')
        lifecycle.record_backend_result('/rideRequests/'+rid,r.json())
        r=request('POST','/ride-requests',json=payload,headers=headers)
        check(r.status_code==200 and r.json()['requestId']==rid and r.json()['status']=='CANCELLED','retry preserves cancellation')
        if scope.ride_only:
            current=request('GET',path)
            check(current.status_code==200 and current.json()['status']=='CANCELLED','owner reads cancelled state')
            lifecycle.record_backend_result('/rideRequests/'+rid,current.json())
            check(request('PATCH',path+'/status',2,json={'status':'ACCEPTED'}).status_code==409,'terminal transition denied')
            final=request('GET',path)
            check(final.status_code==200 and final.json()['status']=='CANCELLED','409 preserves terminal state')
            lifecycle.record_backend_result('/rideRequests/'+rid,final.json())
            return {'checks':checks,'passed':len(checks),'verificationMode':'HTTP and storage readback',
                    'requestId':rid,'guidanceSessionsCreated':0,'authAccountsCreated':0}
        seed_user=0
        seed_label='legacy seed denied to passenger (admin guard tested offline)' if scope.main_project_test else 'legacy seed denied even to test admin'
        check(request('POST','/firebase/initialize',seed_user,json={'reset':True}).status_code==403,seed_label)
        if lifecycle.journal.data['pendingSession'] or any(p.startswith('/v3GuidanceSessions/') for p in lifecycle.journal.data['records']):
            raise CloudTestConfigurationError('A prior session creation exists; cleanup before starting another run')
        lifecycle.journal.data['pendingSession']=True
        lifecycle.journal.save()
        session=request('POST','/guidance/session',json={'wakeWord':'紐⑤퉬'});check(session.status_code==200,'owned guidance session')
        sid=session.json()['sessionId']
        session_path='/v3GuidanceSessions/'+sid
        lifecycle.backend_intent(session_path)
        lifecycle.journal.data['pendingSession']=False
        lifecycle.journal.save()
        lifecycle.record_backend_result(session_path,session.json())
        check(True,'session RTDB snapshot independently verified')
        check(request('GET','/guidance/state',1,params={'sessionId':sid}).status_code==403,'foreign guidance session denied')
        check(request('GET',f'/ai-vision/v2/sessions/{sid}/observations').status_code==503,'Vision remains local-only')
        r=c.get(config['databaseUrl'].rstrip('/')+scope.storage_path('/rideRequests/'+rid)+'.json',params={'auth':tokens[accounts[0]['uid']]})
        check(r.status_code in {401,403},'real RTDB direct sensitive read denied')
    return {'checks':checks,'passed':len(checks),'actualFirebase':True,'mockTransport':False,'requestId':rid,
            'deferredChecks':bodyplan['deferredAdminChecks']}


def validate_stage_credential(stage,config):
    # CLI stage guard, before any Admin SDK or credential refresh. No Owner fallback.
    raw=os.getenv('GOOGLE_APPLICATION_CREDENTIALS','')
    if not raw or os.getenv('FIREBASE_SERVICE_ACCOUNT_PATH'):
        raise CloudTestConfigurationError('An explicit keyless stage-specific ADC file is required')
    info=json.loads(Path(raw).read_text(encoding='utf-8'))
    account=('mobi-ct-cleanup' if stage=='cleanup' else 'mobi-ct-runtime'
             if stage in {'backend','backend-smoke','flutter-smoke','ride-smoke','auth-reuse-check'} or (config.get('executionMode')=='ride-only' and stage in {'preflight','rtdb-bootstrap'}) else 'mobi-ct-bootstrap')
    target=f'{account}@{config["projectId"]}.iam.gserviceaccount.com'
    expected='https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/'+target+':generateAccessToken'
    if info.get('type')!='impersonated_service_account' or info.get('service_account_impersonation_url')!=expected or info.get('delegates'):
        raise CloudTestConfigurationError('ADC identity differs from the exact approved stage identity')
    if any(os.getenv(k) for k in ('CLOUDSDK_AUTH_ACCESS_TOKEN','CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE',
                                 'GOOGLE_OAUTH_ACCESS_TOKEN','CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT')):
        raise CloudTestConfigurationError('Conflicting authentication override')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=('plan','prepare','backend','bootstrap','smoke','preflight','auth-bootstrap','rtdb-bootstrap','backend-smoke','flutter-smoke','cleanup','auth-reuse-check','ride-smoke'))
    p.add_argument('--config',type=Path,required=True);p.add_argument('--output',type=Path)
    p.add_argument('--allow-main-project-test',action='store_true',help='Additional consent for the reviewed main-project run')
    p.add_argument('--apply',action='store_true');p.add_argument('--approved-project-id');p.add_argument('--approved-run-id')
    p.add_argument('--case-id',default='preview-only')
    p.add_argument('--journal',type=Path)
    p.add_argument('--approved-stage',choices=('backend','preflight','auth-bootstrap','rtdb-bootstrap','backend-smoke','flutter-smoke','cleanup','auth-reuse-check','ride-smoke'))
    p.add_argument('--approved-plan-sha256')
    p.add_argument('--confirm-test-clients-stopped',action='store_true')
    args=p.parse_args(argv)
    try:
        config=load_config(args.config)
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{7,31}',args.case_id):raise CloudTestConfigurationError('Invalid smoke case ID')
        if args.action=='prepare':
            if args.output is None:raise CloudTestConfigurationError('prepare needs --output')
            prepare(config,args.output);print('Prepared public defines locally; no network.');return 0
        if not args.apply or args.action=='plan':
            print(json.dumps(execution_plan(config,args.case_id),ensure_ascii=False,indent=2));return 0
        if args.approved_project_id!=config['projectId'] or args.approved_run_id!=config['runId']:
            raise CloudTestConfigurationError('Explicit approved project/run must match the reviewed plan')
        if config.get('mainProjectTest') and not args.allow_main_project_test:
            raise CloudTestConfigurationError('Main-project apply requires --allow-main-project-test and the reviewed exact project/run')
        if args.action in {'bootstrap','smoke'}:
            raise CloudTestConfigurationError('Combined/unjournaled mutations are disabled; use the explicit lifecycle stages')
        approval=execution_plan(config,args.case_id)
        if args.approved_stage!=args.action or args.approved_plan_sha256!=approval['planSha256']:
            raise CloudTestConfigurationError('Exact stage and plan hash approval are required')
        validate_stage_credential(args.action,config)
        if args.action=='cleanup' and not args.confirm_test_clients_stopped:
            raise CloudTestConfigurationError('Confirm that this run test clients and backend are stopped before cleanup')
        if args.action=='backend':
            configure(config)
            import uvicorn
            uvicorn.run('app.cloud_test:create_app',factory=True,host='127.0.0.1',port=config['backendPort'],workers=1,proxy_headers=False)
        else:
            if args.journal is None or args.case_id=='preview-only':
                raise CloudTestConfigurationError('An external journal and unique case ID are required')
            from scripts.cloud_test_lifecycle import Lifecycle
            lifecycle=Lifecycle(sys.modules[__name__],config,args.case_id,args.journal)
            password=None
            if args.action in {'auth-bootstrap','backend-smoke','ride-smoke'}:
                password=os.environ.pop('MOBI_CLOUD_TEST_PASSWORD',None) or getpass.getpass('Unique cloud-test password (not logged): ')
            result=lifecycle.run(args.action,password)
            print(json.dumps(result,ensure_ascii=False,indent=2))
            if result.get('status') in {'PARTIAL','FAILED','NOT_VERIFIED','HISTORICAL_PASS'}:
                return 1
        return 0
    except (KeyboardInterrupt,EOFError):
        print('Cloud-test cancelled.',file=sys.stderr);return 130
    except Exception as exc:
        # Firebase/httpx errors may embed tokens, URLs or credential paths.
        reason=str(exc) if isinstance(exc,CloudTestConfigurationError) else type(exc).__name__
        print('Cloud-test failed closed: '+reason+'. Partial test resources may remain.',file=sys.stderr)
        return 1


if __name__=='__main__':raise SystemExit(main())
