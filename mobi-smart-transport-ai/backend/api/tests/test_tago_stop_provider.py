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
    with pytest.raises(ValueError,match="^TAGO_STOP_READ_TIMEOUT$"):s.search_by_name(stop_name="청주대학교")


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
    with pytest.raises(ValueError,match="TAGO_STOP_READ_TIMEOUT"):
        s.search_by_name(stop_name="충북대학교입구")
    assert not s._queries


def test_destination_preview_prepares_shared_stops_for_route_search(monkeypatch):
    from fastapi.testclient import TestClient
    from app.api.routes import v3_bus
    from app.main import app
    from app.services import cheongju_bus_stops_service as stops
    from app.services.cheongju_route_planner import CheongjuRoutePlanner
    from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode

    name = "청주대학교.뉴시스"
    alight = dict(row("CJB284000031", lat=36.65074073), nodenm=name, gpslong=127.48910)
    catalog, calls = service(monkeypatch, [row(), alight])
    monkeypatch.setenv("CHEONGJU_BUS_STOPS_PROVIDER", "tago")
    monkeypatch.setattr(stops, "_shared_bus_stops_service", lambda provider: catalog)
    monkeypatch.setattr(v3_bus, "_destination_resolver", DestinationCandidateResolver())
    origin = {"originLat": 36.63443041, "originLng": 127.454072}
    preview = TestClient(app).get("/bus/destination-candidates", params={"q": name, "mode": "live", **origin})
    assert preview.status_code == 200
    prepared = preview.json()
    assert prepared["status"] == "RESOLVED" and prepared["fallbackSource"] == "PUBLIC_API"
    assert len(calls) == 2  # Reference coordinates, then origin coordinates.
    assert all(request.url.path.endswith("/getCrdntPrxmtSttnList") for request in calls)
    assert calls[0].url.params["gpsLati"] == "36.65074073"
    assert calls[0].url.params["gpsLong"] == "127.48905996"
    assert calls[0].extensions["timeout"]["read"] == 2.0
    assert prepared["topCandidate"]["longitude"] == alight["gpslong"]

    sequence = RouteSequence("CJB270002000", "105", (
        RouteStopNode("CJB271000129", "충북대학교입구", 18),
        RouteStopNode("CJB284000031", name, 29),
    ), source=FallbackSource.PUBLIC_API)
    planner = CheongjuRoutePlanner()
    monkeypatch.setattr(planner, "_route_sequences", lambda *, live: [sequence])
    with stops.stop_cache_only():
        planned = planner.plan(heard_text="청주대학교·뉴시스", origin_lat=origin["originLat"],
                               origin_lng=origin["originLng"], live=True)
    assert len(calls) == 2
    reused = planned.destination.model_dump(mode="json")
    for field in ("originStops", "destinationStops"):
        assert reused[field][0]["cacheHit"]
        assert reused[field][0]["source"] == "PUBLIC_API"
        assert reused[field][0]["fetchedAt"] == prepared[field][0]["fetchedAt"]
    assert planned.recommendedPlan is not None, planned.model_dump(mode="json")
    assert planned.recommendedPlan.segments[0].routeId == "CJB270002000"


@pytest.mark.parametrize(("query", "expected_status"), [
    ("충북대학교 가고싶어", "NEEDS_CONFIRMATION"),
    ("충북대학교입구역", "RESOLVED"),
])
def test_chungbuk_campus_and_entrance_use_verified_bus_stops(monkeypatch, query, expected_status):
    hospital = dict(row("hospital"), nodenm="충북대학교병원")
    catalog, calls = service(monkeypatch, [row(), row("CJB271000091"), hospital])
    result = DestinationCandidateResolver(stop_catalog=catalog).resolve(heard_text=query, live=True)

    assert result.status.value == expected_status
    assert result.fallbackSource == FallbackSource.PUBLIC_API
    assert result.topCandidate.name == "충북대학교입구"
    assert {stop.stopId for stop in result.destinationStops} == {"CJB271000091", "CJB271000129"}
    assert len(calls) == 1 and calls[0].url.path.endswith("/getCrdntPrxmtSttnList")
    if expected_status == "NEEDS_CONFIRMATION":
        assert "충북대학교입구 정류장" in result.question


def test_cheongju_campus_asks_before_using_verified_nyusis_stop(monkeypatch):
    record = dict(row("CJB284000031", lat=36.65074073), nodenm="청주대학교.뉴시스", gpslong=127.48905996)
    catalog, calls = service(monkeypatch, [record])
    resolver = DestinationCandidateResolver(stop_catalog=catalog)
    result = resolver.resolve(heard_text="청주대학교", live=True)

    assert result.status.value == "NEEDS_CONFIRMATION"
    assert result.fallbackSource == FallbackSource.PUBLIC_API
    assert result.topCandidate.stopId == "CJB284000031"
    assert result.topCandidate.name in result.question
    assert resolver.resolve(heard_text=result.topCandidate.name, live=True).status.value == "RESOLVED"
    assert len(calls) == 1 and calls[0].url.path.endswith("/getCrdntPrxmtSttnList")


@pytest.mark.parametrize("node, name", [("CJB284000032", "청주대학교.뉴시스"), ("CJB284000031", "다른 정류장")])
def test_nyusis_anchor_requires_live_stop_id_and_name(monkeypatch, node, name):
    record = dict(row(node, lat=36.65074073), nodenm=name, gpslong=127.48905996)
    catalog, calls = service(monkeypatch, [record])
    result = DestinationCandidateResolver(stop_catalog=catalog).resolve(heard_text="청주대학교·뉴시스", live=True)
    assert result.status.value == "NOT_FOUND" and result.fallbackSource == FallbackSource.PUBLIC_API
    assert result.topCandidate is None and not result.destinationStops
    assert len(calls) == 1 and calls[0].url.path.endswith("/getCrdntPrxmtSttnList")


def test_nyusis_nearby_timeout_never_falls_back_to_name_or_seed(monkeypatch):
    catalog, calls = service(monkeypatch, [])

    def timeout(request):
        calls.append(request)
        raise httpx.ReadTimeout("offline timeout", request=request)

    catalog._client = httpx.Client(transport=httpx.MockTransport(timeout))
    result = DestinationCandidateResolver(stop_catalog=catalog).resolve(heard_text="청주대학교·뉴시스", live=True)
    assert result.fallbackSource == FallbackSource.ERROR and result.topCandidate is None
    assert len(calls) == 1 and calls[0].url.path.endswith("/getCrdntPrxmtSttnList")


@pytest.mark.parametrize("invalid", ["source", "expired", "future", "naive"])
def test_prepared_cache_rejects_invalid_provenance_without_network(monkeypatch, invalid):
    from dataclasses import replace
    from datetime import timedelta
    from app.services.cheongju_bus_stops_service import stop_cache_only

    catalog, calls = service(monkeypatch, [row()])
    original = catalog.search_by_name(stop_name="충북대학교입구")[0]
    key, (cached_at, _) = next(iter(catalog._queries.items()))
    bad_row = {
        "source": replace(original, endpoint="https://odcloud.invalid/stops"),
        "expired": replace(original, fetched_at=original.fetched_at - timedelta(seconds=60)),
        "future": replace(original, fetched_at=original.fetched_at + timedelta(minutes=1)),
        "naive": replace(original, fetched_at=original.fetched_at.replace(tzinfo=None)),
    }[invalid]
    catalog._queries[key] = (cached_at, (bad_row,))

    with stop_cache_only(), pytest.raises(ValueError, match="TAGO_STOP_CACHE_NOT_READY"):
        catalog.search_by_name(stop_name="충북대학교입구")
    assert len(calls) == 1 and not catalog._queries


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


def test_empty_exact_search_does_not_substitute_seed_or_extra_lookup(monkeypatch):
    s,calls=service(monkeypatch,[])
    class NoLocal:
        def search(self,*args,**kwargs): return []
    resolver=DestinationCandidateResolver(stop_catalog=s,local_search=NoLocal())
    resolver._build_candidates("청주대학교.뉴시스",normalized="청주대학교뉴시스",origin_lat=None,origin_lng=None,live=True)
    assert len(calls)==1 and calls[0].url.params["nodeNm"]=="청주대학교.뉴시스"


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

def test_live_campus_uses_provider_coordinates_not_exact_seed(monkeypatch):
    record={**row(node='CJB284000031',lat=36.65074073),'nodenm':'청주대학교.뉴시스','gpslong':127.48950966}
    s,calls=service(monkeypatch,[record])
    result=DestinationCandidateResolver(stop_catalog=s).resolve(heard_text='청주대학교',origin_lat=36.63443041,origin_lng=127.454072,live=True)
    assert result.topCandidate.stopId=='CJB284000031'
    assert result.topCandidate.latitude==record['gpslati']
    assert result.topCandidate.source==FallbackSource.PUBLIC_API
    assert all(c.source==FallbackSource.PUBLIC_API for c in result.candidates)
    assert not any(r.url.params.get('gpsLong')=='127.49519913' for r in calls)


def test_live_empty_campus_never_falls_back_to_seed(monkeypatch):
    s,calls=service(monkeypatch,[])
    resolver=DestinationCandidateResolver(stop_catalog=s)
    empty=resolver.resolve(heard_text='청주대학교',live=True)
    assert empty.topCandidate is None and not empty.candidates
    assert empty.fallbackSource==FallbackSource.PUBLIC_API and len(calls)==1
    mock=resolver.resolve(heard_text='청주대학교',live=False)
    assert mock.topCandidate.source==FallbackSource.MOCK


@pytest.mark.parametrize('failure,code',[(httpx.ReadTimeout,'TAGO_STOP_READ_TIMEOUT'),(httpx.ConnectTimeout,'TAGO_STOP_CONNECT_TIMEOUT'),(httpx.ConnectError,'TAGO_STOP_CONNECTION_ERROR')])
def test_live_failure_is_not_normal_empty_and_logs_no_secret(monkeypatch,caplog,failure,code):
    s,_=service(monkeypatch,[])
    def fail(req):raise failure('test+key https://secret.invalid?serviceKey=secret',request=req)
    s._client=httpx.Client(transport=httpx.MockTransport(fail))
    result=DestinationCandidateResolver(stop_catalog=s).resolve(heard_text='청주대학교',live=True)
    assert result.topCandidate is None and result.fallbackSource==FallbackSource.ERROR
    assert '조회에 실패' in result.question and code in caplog.text
    assert 'test+key' not in caplog.text and 'secret.invalid' not in caplog.text
    assert not s._queries


def test_dot_variant_uses_one_canonical_query_and_cache(monkeypatch):
    s,calls=service(monkeypatch,[{**row(),'nodenm':'청주대학교.뉴시스'}])
    assert s.search_by_name(stop_name='청주대학교·뉴시스')
    assert s.search_by_name(stop_name='청주대학교.뉴시스')[0].cache_hit
    assert len(calls)==1 and calls[0].url.params['nodeNm']=='청주대학교.뉴시스'
    assert calls[0].extensions['timeout']['read']==2.0


def test_http_failure_logs_status_not_upstream_payload(monkeypatch,caplog):
    s,calls=service(monkeypatch,[],status=503)
    result=DestinationCandidateResolver(stop_catalog=s).resolve(heard_text='청주대학교',live=True)
    assert result.fallbackSource==FallbackSource.ERROR
    assert 'status=503' in caplog.text and 'TAGO_STOP_HTTP_ERROR' in caplog.text
    assert 'test+key' not in caplog.text and len(calls)==1
