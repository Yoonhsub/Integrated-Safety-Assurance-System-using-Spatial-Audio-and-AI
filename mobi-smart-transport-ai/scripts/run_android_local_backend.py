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
    parser.add_argument('--trace',type=Path,required=True)
    args=parser.parse_args(argv)
    if not args.enable_local_test_auth:
        parser.error('Explicit --enable-local-test-auth required; production auth is never changed')
    root=Path(__file__).resolve().parents[1]
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

if __name__=='__main__':raise SystemExit(main())
