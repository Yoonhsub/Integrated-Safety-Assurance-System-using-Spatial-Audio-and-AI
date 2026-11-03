"""Explicit loopback-only Fake identity host for the existing FastAPI app.

Never import this into the production app. No Firebase SDK credentials or data.
"""
from __future__ import annotations
import argparse, asyncio, json, os, socket, sys, threading, time
from pathlib import Path
from datetime import datetime, timezone
from starlette.requests import HTTPConnection


def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument('--enable-local-test-auth',action='store_true')
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--camera-vision',action='store_true')
    parser.add_argument('--connection-file',type=Path)
    parser.add_argument('--control-dir',type=Path)
    parser.add_argument('--trace',type=Path,required=True)
    args=parser.parse_args(argv)
    if not args.enable_local_test_auth:
        parser.error('Explicit --enable-local-test-auth required; production auth is never changed')
    root=Path(__file__).resolve().parents[1]
    if args.camera_vision:
        if args.self_test or args.connection_file is None or args.control_dir is None:
            parser.error('--camera-vision requires --connection-file and --control-dir; no --self-test')
        return camera_vision_host(args, root)
    for key in tuple(os.environ):
        if key.startswith(('GOOGLE_','FIREBASE_','MOBI_CLOUD_TEST')) or key.endswith('API_KEY'):
            os.environ.pop(key,None)
    os.environ.update(APP_ENV='test',FIREBASE_USE_MOCK='true',FIREBASE_USE_ADC='false',
        FCM_ENABLED='false',FCM_USE_MOCK='true',PUBLIC_DATA_USE_MOCK='true',MOBI_SYNTHETIC_GUIDANCE='false')
    import dotenv
    dotenv.load_dotenv=lambda *a,**k:False
    # Windows asyncio's internal socketpair is allocated before outbound denial.
    loop=asyncio.new_event_loop()
    listener=socket.socket()
    listener.bind(('127.0.0.1',0 if args.self_test else 8000))
    port=listener.getsockname()[1]
    connect=socket.socket.connect;resolve=socket.getaddrinfo
    def deny_connect(self,address):
        if not args.self_test or not isinstance(address,tuple) or address[0]!='127.0.0.1' or address[1]!=port:
            raise RuntimeError('Outbound connections forbidden in local Backend')
        return connect(self,address)
    def deny_resolve(host,*a,**kw):
        if not args.self_test or host!='127.0.0.1':raise RuntimeError('External DNS forbidden')
        return resolve(host,*a,**kw)
    socket.socket.connect=deny_connect;socket.getaddrinfo=deny_resolve
    sys.path[:0]=[str(root),str(root/'backend/api')]
    from app.main import app
    from app.security import get_principal,Principal
    from app.services import firebase_client as storage
    from app.services.firebase_client import FirebaseClient,FirebaseSettings
    from fastapi import HTTPException
    from starlette.requests import HTTPConnection
    from starlette.responses import JSONResponse
    fake=FirebaseClient(FirebaseSettings(None,None,None,None,True))
    storage.firebase_client=fake
    async def identity(connection:HTTPConnection):
        if connection.url.path=='/health':return None
        identities={'Bearer offline-only.owner':Principal('owner','passenger'),
                    'Bearer offline-only.other':Principal('other','passenger'),
                    'Bearer offline-only.admin':Principal('admin','admin')}
        principal=identities.get(connection.headers.get('authorization'))
        if principal is None:raise HTTPException(401,'Explicit local fixture identity required')
        return principal
    app.dependency_overrides[get_principal]=identity
    args.trace.parent.mkdir(parents=True,exist_ok=True)
    allowed={('GET','/health'),('POST','/guidance/session'),('GET','/guidance/state'),
             ('GET','/guidance/safety-events'),('POST','/guidance/reset'),('POST','/guidance/event')}
    @app.middleware('http')
    async def scope(request,call_next):
        pair=(request.method,request.url.path)
        if pair not in allowed:response=JSONResponse({'error':'Outside Android HTTP probe scope'},status_code=403)
        elif pair==('POST','/guidance/event') and (await request.json()).get('event') not in {
            'ROUTE_RECOMMENDED','WAITING_FOR_BUS','BOARDING_CONFIRMATION','BOARDED'}:
            response=JSONResponse({'error':'Outside fixture state transitions'},status_code=403)
        else:response=await call_next(request)
        response.headers['X-Mobi-Local-Probe']='fake-auth-memory-v1'
        attempt=request.headers.get('x-mobi-local-attempt','')
        # Untrusted diagnostic field only; never an authentication decision.
        if len(attempt)>100 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-' for c in attempt):attempt='invalid'
        record={'utc':datetime.now(timezone.utc).isoformat(),'method':request.method,
                'path':request.url.path,'status':response.status_code,'attemptId':attempt}
        with args.trace.open('a',encoding='utf-8') as file:file.write(json.dumps(record)+'\n')
        return response
    import uvicorn
    server=uvicorn.Server(uvicorn.Config(app,host='127.0.0.1',port=port,access_log=False,log_level='warning'))
    def serve():loop.run_until_complete(server.serve(sockets=[listener]))
    if not args.self_test:
        print(json.dumps({'mode':'LOCAL_FAKE_AUTH_MEMORY_ONLY','host':'127.0.0.1','port':port}),flush=True)
        try:serve()
        finally:
            server.should_exit=True;listener.close();loop.close()
        return 0
    worker=threading.Thread(target=serve,daemon=True);worker.start()
    rows=[]
    try:
        for _ in range(200):
            if server.started:break
            time.sleep(.01)
        assert server.started
        import urllib.request,urllib.error
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def request(method,path,code,who=None,body=None):
            headers={'Content-Type':'application/json','X-Mobi-Local-Attempt':f'host-selftest-{len(rows)+1}'}
            if who:headers['Authorization']='Bearer offline-only.'+who
            req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,headers=headers,
                data=None if body is None else json.dumps(body).encode(),method=method)
            try:
                with opener.open(req,timeout=5) as response:actual=response.status;value=json.load(response)
            except urllib.error.HTTPError as error:actual=error.code;value=json.load(error)
            rows.append(actual);assert actual==code,(method,path,actual,code)
            return value
        assert request('GET','/health',200)['firebaseMode']=='mock'
        request('POST','/guidance/session',401,body={})
        sid=request('POST','/guidance/session',200,'owner',{})['sessionId']
        request('GET','/guidance/state?sessionId='+sid,200,'owner')
        old=request('GET','/guidance/safety-events?sessionId='+sid,200,'owner')
        assert not old['events']
        request('GET','/guidance/state?sessionId='+sid,403,'other')
        request('POST','/guidance/reset',200,'owner',{'sessionId':sid,'event':'RESET'})
        new=request('GET','/guidance/safety-events?sessionId='+sid,200,'owner')
        assert new['generation']!=old['generation'] and not new['events']
        for event in ['ROUTE_RECOMMENDED','WAITING_FOR_BUS','BOARDING_CONFIRMATION','BOARDED']:
            request('POST','/guidance/event',200,'admin',{'sessionId':sid,'event':event})
        request('GET','/guidance/safety-events?sessionId='+sid,403,'owner')
        request('POST','/ai-vision/events',403,'admin',{})
        request('POST','/safety-events',403,'admin',{})
        assert fake.get('/safetyEvents') is None
        assert fake.get('/v3GuidanceSessions/'+sid)['state']=='BOARDED'
        print(json.dumps({'result':'LOCAL_HTTP_SELF_TEST_PASS','checks':len(rows),
                          'storage':'memory','auth':'Fake','androidRuntime':False,'safetyEventsCreated':0}))
    finally:
        server.should_exit=True;worker.join(8);listener.close();loop.close()
        if worker.is_alive():raise RuntimeError('Local server shutdown failed')
    return 0



def camera_vision_host(args, root):
    """PC-only fixture launcher for the SAME app/routes; no mobile admin key.

    A local operator writes bind.json with the displayed Passenger sessionId.
    Only this PC process holds the ephemeral admin token and invokes existing
    register/bind HTTP APIs. No new Backend endpoint or auth protocol is added.
    """
    import secrets
    from types import SimpleNamespace
    from datetime import timedelta
    for key in tuple(os.environ):
        if key.startswith(('GOOGLE_','FIREBASE_','MOBI_CLOUD_TEST')) or key.endswith('API_KEY'):
            os.environ.pop(key,None)
    os.environ.update(APP_ENV='local-demo',MOBI_LOCAL_DEMO='1',PYTHON_DOTENV_DISABLED='1',
        FIREBASE_PROJECT_ID='demo-mobi-local',FIREBASE_AUTH_EMULATOR_HOST='127.0.0.1:9099',
        FIREBASE_DATABASE_EMULATOR_HOST='127.0.0.1:9000',
        FIREBASE_DATABASE_URL='https://demo-mobi-local-default-rtdb.firebaseio.com',
        FIREBASE_USE_MOCK='false',PUBLIC_DATA_USE_MOCK='true',
        MOBI_SYNTHETIC_GUIDANCE='false',FCM_ENABLED='false')
    import dotenv
    dotenv.load_dotenv=lambda *a,**k:False
    # No destructive cleanup: use a new control directory for every run.
    control=args.control_dir.resolve();control.mkdir(parents=True,exist_ok=False)
    args.connection_file.parent.mkdir(parents=True,exist_ok=True)
    if args.connection_file.exists():raise RuntimeError('Use a new connection file; never overwrite credentials')
    sys.path[:0]=[str(root),str(root/'backend/api')]
    loop=asyncio.new_event_loop()
    listener=socket.socket();listener.bind(('127.0.0.1',8000))
    def audit(event,values):
        if event=='socket.connect':
            address=values[1];frame=sys._getframe();internal=False
            while frame:
                if frame.f_code.co_name=='_fallback_socketpair' and frame.f_code.co_filename.endswith('socket.py'):internal=True;break
                frame=frame.f_back
            if not isinstance(address,tuple) or address[0]!='127.0.0.1' or (address[1]!=8000 and not internal):
                raise RuntimeError('Only owned loopback Backend traffic permitted')
        if event=='open' and isinstance(values[0],str) and 'application_default_credentials' in values[0]:
            raise RuntimeError('ADC access forbidden')
    sys.addaudithook(audit)
    from app.main import app
    from app import security
    from app.api.routes import vision_v2
    from app.local_emulator import validate_local_emulators
    from app.services.firebase_client import FirebaseClient,FirebaseSettings
    from app.services.v3_guidance_store import v3_guidance_store as sessions
    from app.services.vision_binding_service import VisionBindingService
    from app.services.safety_event_service import SafetyEventService
    from app.services import session_safety_delivery
    from starlette.responses import JSONResponse
    import uvicorn,httpx
    validate_local_emulators()
    fake=FirebaseClient(FirebaseSettings(None,None,None,None,True));sessions.clear()
    sessions._persist=lambda record:fake.set('v3GuidanceSessions/'+record.session_id,record.to_response().model_dump(mode='json'))
    service=vision_v2.vision_binding_service=VisionBindingService(storage=fake)
    created=datetime.now(timezone.utc);expiry=created+timedelta(minutes=30)
    roles={'local-passenger':'passenger','local-producer':'vision_producer','local-admin':'admin'}
    credentials={uid:secrets.token_urlsafe(32) for uid in roles};identities={token:uid for uid,token in credentials.items()}
    security.firebase_auth_app=lambda:object()
    def verify(token,**kwargs):
        if token not in identities or datetime.now(timezone.utc)>=expiry:
            raise security.auth.InvalidIdTokenError('Local test credential is invalid')
        assert kwargs['check_revoked'] and kwargs['clock_skew_seconds']==0
        return {'uid':identities[token],'auth_time':int(created.timestamp()),'exp':expiry.timestamp()}
    security.auth.verify_id_token=verify
    security.auth.get_user=lambda uid,**kw:SimpleNamespace(disabled=False,custom_claims={'mobi_role':roles[uid]})
    counts={'safetyCreate':0,'publish':0}
    def forbidden(which):
        def call(*a,**k):counts[which]+=1;raise RuntimeError('Safety output forbidden in camera Preview')
        return call
    SafetyEventService.create=forbidden('safetyCreate');session_safety_delivery.publish=forbidden('publish')
    args.trace.parent.mkdir(parents=True,exist_ok=True)
    trace_lock=threading.Lock()
    @app.middleware('http')
    async def scope(request,nextcall):
        path=request.url.path
        allowed=(path=='/health' or path in {'/guidance/session','/guidance/state','/guidance/safety-events','/guidance/reset','/guidance/vision-lease','/guidance/vision-lease/operations'} or path.startswith('/ai-vision/v2/'))
        if not allowed:response=JSONResponse({'error':'Outside local camera Preview scope'},status_code=403)
        elif path=='/ai-vision/v2/events' and (control/'fault').exists():response=JSONResponse({'error':'Explicit PC fault injection'},status_code=503)
        else:response=await nextcall(request)
        response.headers['X-Mobi-Local-Probe']='fake-auth-memory-vision-v1'
        attempt=request.headers.get('x-mobi-local-attempt','')
        if len(attempt)>100 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-' for c in attempt):attempt='invalid'
        row={'utc':datetime.now(timezone.utc).isoformat(),'method':request.method,'path':path,
             'status':response.status_code,'attemptId':attempt}
        if path=='/ai-vision/v2/events' and response.status_code==202:
            item=service._observations.get('android-camera-local')
            if item:row['preview']=item.preview
        with trace_lock,args.trace.open('a',encoding='utf-8') as log:log.write(json.dumps(row,ensure_ascii=False)+'\n')
        return response
    server=uvicorn.Server(uvicorn.Config(app,host='127.0.0.1',port=8000,access_log=False,log_level='warning'))
    worker=threading.Thread(target=lambda:loop.run_until_complete(server.serve(sockets=[listener])),daemon=True);worker.start()
    try:
        for _ in range(300):
            if server.started:break
            time.sleep(.02)
        if not server.started:raise RuntimeError('Local camera host failed to start')
        with httpx.Client(base_url='http://127.0.0.1:8000',trust_env=False,timeout=5) as client:
            header={'Authorization':'Bearer '+credentials['local-admin']}
            registered=client.put('/ai-vision/v2/cameras/android-camera-local',headers=header,
                                  json={'producerId':'local-producer','sourceType':'android_camera'})
            if registered.status_code!=200:raise RuntimeError('Admin camera registration failed')
            args.connection_file.write_text(json.dumps({'scope':'local-camera-preview-v1','baseUrl':'http://127.0.0.1:8000',
                'passengerUid':'local-passenger','producerUid':'local-producer','cameraId':'android-camera-local',
                'passengerToken':credentials['local-passenger'],'producerToken':credentials['local-producer'],
                'expiresAt':expiry.isoformat()},indent=2),encoding='utf-8')
            print(json.dumps({'mode':'CAMERA_PREVIEW_FAKE_AUTH_MEMORY','host':'127.0.0.1','port':8000,'expiresAt':expiry.isoformat()}),flush=True)
            while not (control/'stop').exists():
                command=control/'bind.json'
                if command.exists():
                    # Operator-only local file, never a Passenger network route.
                    try:
                        value=json.loads(command.read_text(encoding='utf-8-sig'))
                        if set(value)!={'sessionId'} or not isinstance(value['sessionId'],str):raise ValueError()
                        response=client.post('/ai-vision/v2/bindings',headers=header,json={'cameraId':'android-camera-local','sessionId':value['sessionId']})
                        result={'status':response.status_code,'sessionId':value['sessionId']}
                    except Exception:result={'status':'invalid_local_command'}
                    (control/'binding-result.json').write_text(json.dumps(result),encoding='utf-8');command.unlink()
                time.sleep(.1)
    finally:
        server.should_exit=True;worker.join(10);listener.close();loop.close()
        if worker.is_alive():raise RuntimeError('Local camera server shutdown failed')
        result={**counts,'safetyItems':sum(len(record.safety_items) for record in sessions._sessions.values()),'stopped':True,'singleWorkerMemoryOnly':True}
        (control/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    return 0

if __name__=='__main__':raise SystemExit(main())
