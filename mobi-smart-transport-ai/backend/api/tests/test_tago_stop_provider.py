import httpx
import pytest
from app.services.cheongju_bus_stops_service import TagoBusStopsService, create_bus_stops_service
from app.services.destination_candidate_resolver import DestinationCandidateResolver
from app.schemas.v3 import DestinationCandidate, DestinationCandidateType, FallbackSource


def row(node="CJB271000129", city="33010", lat=36.63443041):
    return {"nodeid":node,"nodenm":"충북대학교입구","gpslati":lat,"gpslong":127.454072,"citycode":city}


def service(monkeypatch, rows, code="00", total=None, status=200):
    monkeypatch.setenv("CHEONGJU_BUS_STOPS_ENABLED", "true")
    monkeypatch.setenv("PUBLIC_DATA_API_KEY", "test+key")
    calls=[]
    def handler(req):
        calls.append(req)
        assert req.url.params["serviceKey"] == "test+key"
        return httpx.Response(status,json={"response":{"header":{"resultCode":code},"body":{"totalCount":len(rows) if total is None else total,"pageNo":1,"items":{"item":rows}}}})
    return TagoBusStopsService(client=httpx.Client(transport=httpx.MockTransport(handler))), calls


def test_nearby_city_dedup_sort_and_actual_ids(monkeypatch):
    s,calls=service(monkeypatch,[row(),row(),row("OTHER","25"),row("far",lat=36.65)])
    result=s.find_nearby(origin_lat=36.63443041,origin_lng=127.454072)
    assert [r.service_id for r in result]==["CJB271000129"]
    assert result[0].distance_meters == 0
    assert len(calls)==1 and calls[0].url.path.endswith("getCrdntPrxmtSttnList")
    assert "cityCode" not in calls[0].url.params


def test_name_keeps_platforms_and_rejects_ambiguous_single(monkeypatch):
    s,calls=service(monkeypatch,[row(),row("CJB271000091")])
    assert len(s.search_by_name(stop_name="충북대학교입구"))==2
    assert s.find_by_name(stop_name="충북대학교입구") is None
    assert calls[0].url.params["cityCode"]=="33010"
    assert calls[0].url.path.endswith("getSttnNoList")


@pytest.mark.parametrize("code",["00","0"])
def test_empty_is_empty(monkeypatch,code):
    s,_=service(monkeypatch,[],code=code)
    assert s.find_nearby(origin_lat=36.63,origin_lng=127.45)==[]


@pytest.mark.parametrize("kwargs",[{"total":101},{"code":"30"},{"status":401},{"status":503}])
def test_errors_not_empty_or_seed_and_no_key_leak(monkeypatch,kwargs):
    s,calls=service(monkeypatch,[row()],**kwargs)
    with pytest.raises(ValueError) as err:s.find_nearby(origin_lat=36.63,origin_lng=127.45)
    assert "test+key" not in str(err.value) and "https" not in str(err.value)
    assert len(calls)==1


def test_malformed_coordinates_and_missing_city(monkeypatch):
    for bad in [row(lat=float("nan")), {k:v for k,v in row().items() if k!="citycode"}]:
        s,_=service(monkeypatch,[bad])
        with pytest.raises(ValueError):s.find_nearby(origin_lat=36.63,origin_lng=127.45)


def test_failure_retries_next_request_not_cached(monkeypatch):
    s,calls=service(monkeypatch,[],code="30")
    for _ in range(2):
        with pytest.raises(ValueError):s.search_by_name(stop_name="충북대학교입구")
    assert len(calls)==2


def test_resolver_no_seed_for_live_tago_but_mock_unchanged(monkeypatch):
    s,_=service(monkeypatch,[])
    resolver=DestinationCandidateResolver(stop_catalog=s)
    candidate=DestinationCandidate(name="청주대학교",type=DestinationCandidateType.PLACE,confidence=.9,latitude=36.650856501,longitude=127.49519913,source=FallbackSource.MOCK)
    assert resolver._destination_stops_for(candidate,live=True)==[]
    assert resolver._origin_stops(origin_lat=36.6359,origin_lng=127.4596,live=True)==[]
    assert resolver._destination_stops_for(candidate,live=False)


def test_factory_opt_in_and_disabled_no_requests(monkeypatch):
    monkeypatch.setenv("CHEONGJU_BUS_STOPS_PROVIDER","tago")
    monkeypatch.setenv("CHEONGJU_BUS_STOPS_ENABLED","false")
    s=create_bus_stops_service()
    assert isinstance(s,TagoBusStopsService)
    assert s.search_by_name(stop_name="청주대학교")==[]


def test_timeout_is_safe(monkeypatch):
    monkeypatch.setenv("CHEONGJU_BUS_STOPS_ENABLED","true")
    monkeypatch.setenv("PUBLIC_DATA_API_KEY","secret")
    def handler(req):raise httpx.ReadTimeout("secret URL",request=req)
    s=TagoBusStopsService(client=httpx.Client(transport=httpx.MockTransport(handler)))
    with pytest.raises(ValueError,match="^TAGO_STOP_TIMEOUT$"):s.search_by_name(stop_name="청주대학교")


def test_real_node_contract_reaches_resolver_without_injection(monkeypatch):
    s,_=service(monkeypatch,[row()])
    resolver=DestinationCandidateResolver(stop_catalog=s)
    stops=resolver._origin_stops(origin_lat=36.63443041,origin_lng=127.454072,live=True)
    assert len(stops)==1
    assert stops[0].stopId=="CJB271000129"
    assert stops[0].source==FallbackSource.PUBLIC_API


def test_null_id_rejected(monkeypatch):
    s,_=service(monkeypatch,[row(node=None)])
    with pytest.raises(ValueError,match="TAGO_STOP_INVALID_ROW"):
        s.search_by_name(stop_name="충北대학교입구")


def test_cached_name_preserves_origin_time_and_limit(monkeypatch):
    s,calls=service(monkeypatch,[row(),row("second")])
    first=s.search_by_name(stop_name="충북대학교입구",limit=1)
    second=s.search_by_name(stop_name="충북대학교입구",limit=5)
    assert len(calls)==1 and len(second)==2
    assert not first[0].cache_hit and second[0].cache_hit
    assert first[0].fetched_at == second[0].fetched_at
    assert calls[0].extensions["timeout"]["read"] == 2.0
    resolver=DestinationCandidateResolver(stop_catalog=s)
    candidate=resolver._public_stop_candidates("충북대학교입구")[0]
    assert candidate.source == FallbackSource.PUBLIC_API
    assert candidate.cacheHit and candidate.fetchedAt == first[0].fetched_at


def test_cache_expiry_failure_never_returns_stale(monkeypatch):
    import app.services.cheongju_bus_stops_service as module
    clock=[100.0]
    monkeypatch.setattr(module.time,"monotonic",lambda:clock[0])
    s,calls=service(monkeypatch,[row()])
    s.search_by_name(stop_name="충북대학교입구")
    clock[0]+=60
    def fail(req): raise httpx.ReadTimeout("hidden",request=req)
    s._client=httpx.Client(transport=httpx.MockTransport(fail))
    with pytest.raises(ValueError,match="TAGO_STOP_TIMEOUT"):
        s.search_by_name(stop_name="충북대학교입구")
    assert not s._queries


def test_cache_exact_query_isolation_and_empty_not_cached(monkeypatch):
    s,calls=service(monkeypatch,[row()])
    s.search_by_name(stop_name="A")
    s.search_by_name(stop_name="B")
    s.find_nearby(origin_lat=36.63,origin_lng=127.45)
    s.find_nearby(origin_lat=36.631,origin_lng=127.45)
    assert len(calls)==4
    empty,requests=service(monkeypatch,[])
    for _ in range(2): empty.search_by_name(stop_name="A")
    assert len(requests)==2 and not empty._queries


def test_busy_does_not_issue_duplicate_or_wait(monkeypatch):
    s,calls=service(monkeypatch,[row()])
    s._query_lock.acquire()
    try:
        with pytest.raises(ValueError,match="TAGO_STOP_BUSY"):
            s.search_by_name(stop_name="A")
        assert not calls
    finally: s._query_lock.release()


def test_cache_bounded_and_disabled_not_served(monkeypatch):
    s,calls=service(monkeypatch,[row()])
    for i in range(130): s.search_by_name(stop_name=str(i))
    assert len(s._queries)==128
    monkeypatch.setenv("CHEONGJU_BUS_STOPS_ENABLED","false")
    assert s.search_by_name(stop_name="129")==[]
    assert len(calls)==130


def test_owned_transport_reused_without_changing_timeout(monkeypatch):
    import app.services.cheongju_bus_stops_service as module
    s,calls=service(monkeypatch,[row()])
    injected=s._client
    s._client=None
    s._owns_client=True
    created=[]
    def factory(**kwargs):
        created.append(kwargs)
        return injected
    monkeypatch.setattr(module.httpx,"Client",factory)
    s.search_by_name(stop_name="first")
    s.search_by_name(stop_name="second")
    assert len(created)==1 and len(calls)==2
    assert created[0]["timeout"]==2.0
    assert all(r.extensions["timeout"]["read"]==2.0 for r in calls)
    s.close()
    assert injected.is_closed and s._client is None


def test_close_preserves_injected_client(monkeypatch):
    s,_=service(monkeypatch,[row()])
    s.close()
    assert not s._client.is_closed


def test_exact_tago_stop_skips_fuzzy_known_place_lookup(monkeypatch):
    s,calls=service(monkeypatch,[{**row(),"nodenm":"청주대학교.뉴시스"}])
    class NoLocal:
        def search(self,*args,**kwargs): return []
    resolver=DestinationCandidateResolver(stop_catalog=s,local_search=NoLocal())
    result=resolver._build_candidates("청주대학교.뉴시스",normalized="청주대학교뉴시스",origin_lat=None,origin_lng=None,live=True)
    assert len(calls)==1
    assert calls[0].url.params["nodeNm"]=="청주대학교.뉴시스"
    assert result and result[0].stopId=="CJB271000129"


def test_empty_exact_search_keeps_fuzzy_verification(monkeypatch):
    s,calls=service(monkeypatch,[])
    class NoLocal:
        def search(self,*args,**kwargs): return []
    resolver=DestinationCandidateResolver(stop_catalog=s,local_search=NoLocal())
    resolver._build_candidates("청주대학교.뉴시스",normalized="청주대학교뉴시스",origin_lat=None,origin_lng=None,live=True)
    assert any(r.url.params["nodeNm"]=="청주대학교" for r in calls)


def test_shared_factory_reuses_resolver_and_nearby(monkeypatch):
    from app.services.cheongju_bus_stops_service import get_shared_bus_stops_service
    monkeypatch.setenv("CHEONGJU_BUS_STOPS_PROVIDER","tago")
    a=DestinationCandidateResolver();b=DestinationCandidateResolver()
    assert a._stop_catalog is b._stop_catalog is get_shared_bus_stops_service()


def test_camera_miss_blocks_all_external_providers(monkeypatch):
    from app.services.vision_binding_service import vision_binding_service
    monkeypatch.setattr(vision_binding_service,"has_camera_reservation",lambda:True)
    s,calls=service(monkeypatch,[row()])
    class Forbidden:
        def search(self,*args,**kwargs): raise AssertionError("geocoder called")
    result=DestinationCandidateResolver(stop_catalog=s,local_search=Forbidden()).resolve(
        heard_text="충북대학교입구",origin_lat=36.63443041,origin_lng=127.454072,live=True)
    assert not calls and result.status.value=="NOT_FOUND"
    assert "카메라" in result.question and result.fallbackSource==FallbackSource.ERROR


def test_camera_cached_stops_and_expiry_no_network(monkeypatch):
    import app.services.cheongju_bus_stops_service as module
    from app.services.vision_binding_service import vision_binding_service
    clock=[100.0]
    monkeypatch.setattr(module.time,"monotonic",lambda:clock[0])
    s,calls=service(monkeypatch,[row()])
    s.search_by_name(stop_name="충북대학교입구")
    s.find_nearby(origin_lat=36.63443041,origin_lng=127.454072)
    monkeypatch.setattr(vision_binding_service,"has_camera_reservation",lambda:True)
    resolver=DestinationCandidateResolver(stop_catalog=s)
    result=resolver.resolve(heard_text="충북대학교입구",origin_lat=36.63443041,origin_lng=127.454072,live=True)
    assert len(calls)==2 and result.originStops and result.destinationStops
    assert result.originStops[0].cacheHit and result.originStops[0].fetchedAt
    clock[0]+=60
    expired=resolver.resolve(heard_text="충북대학교입구",origin_lat=36.63443041,origin_lng=127.454072,live=True)
    assert len(calls)==2 and expired.status.value=="NOT_FOUND"
    monkeypatch.setattr(vision_binding_service,"has_camera_reservation",lambda:False)
    resolver.resolve(heard_text="충북대학교입구",origin_lat=36.63443041,origin_lng=127.454072,live=True)
    assert len(calls)>2


def test_camera_route_guard_never_calls_route_provider(monkeypatch):
    from app.services.vision_binding_service import vision_binding_service
    from app.services.transit_planner_orchestrator import TransitPlannerOrchestrator
    monkeypatch.setattr(vision_binding_service,"has_camera_reservation",lambda:True)
    s,calls=service(monkeypatch,[row()])
    class Forbidden:
        def __getattr__(self,name): raise AssertionError("route I/O called")
    planner=TransitPlannerOrchestrator(resolver=DestinationCandidateResolver(stop_catalog=s),route_service=Forbidden())
    result=planner.plan(heard_text="충북대학교입구",origin_lat=36.63443041,origin_lng=127.454072,live=True)
    assert not calls and result.status.value=="NOT_FOUND"
    assert "카메라" in result.question


def test_binding_load_guard_includes_gaps_but_not_expiry():
    from app.services.vision_binding_service import VisionBindingService
    from types import SimpleNamespace
    from datetime import datetime, timezone, timedelta
    now=datetime.now(timezone.utc)
    svc=VisionBindingService(utc_clock=lambda:now,mono_clock=lambda:10.0)
    assert not svc.has_camera_reservation()
    svc._bindings['offline']=SimpleNamespace(expires_at=now+timedelta(seconds=1),deadline=11.0)
    assert svc.has_camera_reservation()  # No frame required; never a safety signal.
    svc._bindings['offline'].deadline=10.0
    assert not svc.has_camera_reservation()


def test_legacy_route_api_deferred_before_external_calls(monkeypatch):
    from app.api.routes import v3_bus
    from app.services.vision_binding_service import vision_binding_service
    from fastapi import HTTPException
    monkeypatch.setattr(vision_binding_service,"has_camera_reservation",lambda:True)
    monkeypatch.setattr(v3_bus,"_recommendation_for",lambda *a,**k:pytest.fail("external route lookup"))
    with pytest.raises(HTTPException) as exc:
        v3_bus.route_recommend(destination="청주대학교",originLat=None,originLng=None,mode="live",nluProvider="auto")
    assert exc.value.status_code==409
    assert exc.value.detail["error"]["code"]=="ROUTE_SEARCH_DEFERRED_FOR_CAMERA"


def test_direct_tago_lookup_respects_camera_guard(monkeypatch):
    from app.services.vision_binding_service import vision_binding_service
    monkeypatch.setattr(vision_binding_service,"has_camera_reservation",lambda:True)
    s,calls=service(monkeypatch,[row()])
    with pytest.raises(ValueError,match="TAGO_STOP_CACHE_NOT_READY"):
        s.search_by_name(stop_name="충북대학교입구")
    assert not calls
