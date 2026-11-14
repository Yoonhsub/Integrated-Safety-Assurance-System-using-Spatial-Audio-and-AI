"""Synthetic transport tests only; never contacts TAGO or Firebase."""
import httpx
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.security import get_principal, Principal
from app.services import tago_diagnostics_service as service

client = TestClient(app)

def wire(monkeypatch, payload=None, *, failure=None, code=200):
    captured = []
    real = service.DataGoKrClient
    def handler(request):
        captured.append(request)
        if failure:
            raise failure("test secret must not leak", request=request)
        return httpx.Response(code, json=payload)
    def factory(**kwargs):
        obj = real(api_key="fixture-secret", **kwargs)
        obj.client.close()
        obj.client = httpx.Client(transport=httpx.MockTransport(handler))
        return obj
    monkeypatch.setattr(service, "DataGoKrClient", factory)
    return captured

def envelope(items, total=None):
    return {"response":{"header":{"resultCode":"00"}, "body":{"totalCount":len(items) if total is None else total,"items":{"item":items}}}}

def test_arrival_diagnostic_no_mock_no_timestamp_fabrication(monkeypatch):
    requests = wire(monkeypatch, envelope([{"routeid":"r1","routeno":"502"}]))
    monkeypatch.setenv("PUBLIC_DATA_USE_MOCK", "true")
    monkeypatch.setenv("PUBLIC_DATA_BASE_URL", "https://not-the-provider.invalid")
    result = client.get("/diagnostics/tago/arrivals", params={"cityCode":"25","stopId":"S1"})
    assert result.status_code == 200
    data = result.json()
    assert data["status"] == "SUCCESS" and data["source"] == "PUBLIC_API"
    assert data["fetchedAt"] and data["observedAt"] is None and not data["fallbackUsed"]
    assert data["records"][0]["arrivalSeconds"] is None
    assert data["records"][0]["vehicleType"] is None
    assert data["records"][0]["observedAt"] is None
    assert requests[0].url.host == "apis.data.go.kr"
    assert requests[0].url.params["cityCode"] == "25"
    assert requests[0].url.params["nodeId"] == "S1"
    assert "fixture-secret" not in result.text

def test_location_last_stop_not_gps(monkeypatch):
    requests = wire(monkeypatch, envelope([{"vehicleno":"V1","nodeid":"N1","nodenm":"Stop"}]))
    data = client.get("/diagnostics/tago/locations",params={"cityCode":"33010","routeId":"R1"}).json()
    record = data["records"][0]
    assert record["positionType"] == "LAST_REPORTED_STOP" and record["observedAt"] is None
    assert "latitude" not in record and "longitude" not in record
    assert requests[0].url.params["routeId"] == "R1"

@pytest.mark.parametrize("payload,status,error", [
    (envelope([]), "EMPTY", None),
    ({"response":{"header":{"resultCode":"30","resultMsg":"secret"}}}, "ERROR", "PROVIDER_REJECTED"),
    ({"response":{"body":{"items":""}}}, "ERROR", "MALFORMED_RESPONSE"),
    ({"response":{"header":{"resultCode":"00"},"body":{"items":"","totalCount":4}}}, "ERROR", "MALFORMED_RESPONSE"),
    (envelope([{}]), "ERROR", "MALFORMED_RESPONSE"),
    ([], "ERROR", "MALFORMED_RESPONSE"),
])
def test_error_not_empty_or_mock(monkeypatch, payload, status, error):
    wire(monkeypatch,payload)
    response=client.get("/diagnostics/tago/arrivals",params={"cityCode":"25","stopId":"S1"})
    data=response.json()
    assert data["status"] == status and data["errorCode"] == error
    assert data["records"] == [] and not data["fallbackUsed"]
    assert data["source"] == ("ERROR" if error else "PUBLIC_API")
    assert "secret" not in response.text

@pytest.mark.parametrize("failure,error", [(httpx.ReadTimeout,"UPSTREAM_TIMEOUT"),(httpx.ConnectError,"UPSTREAM_UNAVAILABLE")])
def test_transport_errors(monkeypatch,failure,error):
    wire(monkeypatch,failure=failure)
    data=client.get("/diagnostics/tago/locations",params={"cityCode":"25","routeId":"R1"}).json()
    assert data["errorCode"] == error and data["fetchedAt"] is None

def test_missing_key_no_fallback(monkeypatch):
    monkeypatch.setenv("PUBLIC_DATA_API_KEY", "")
    data=client.get("/diagnostics/tago/arrivals",params={"cityCode":"25","stopId":"S1"}).json()
    assert data["errorCode"] == "SERVICE_KEY_MISSING" and data["source"] == "ERROR"

@pytest.mark.parametrize("params", [{"cityCode":"x","stopId":"S1"},{"cityCode":"25","stopId":"https://evil.invalid"},{"cityCode":"25","stopId":"x"*65}])
def test_invalid_query_rejected_before_transport(monkeypatch,params):
    def forbidden(*a,**kw):
        raise AssertionError("No transport for invalid query")
    monkeypatch.setattr(service,"DataGoKrClient",forbidden)
    assert client.get("/diagnostics/tago/arrivals",params=params).status_code == 422

@pytest.mark.auth_boundary
def test_unauthenticated_denied_before_provider(monkeypatch):
    def forbidden(*a,**kw):
        raise AssertionError("No provider without auth")
    monkeypatch.setattr(service,"DataGoKrClient",forbidden)
    assert client.get("/diagnostics/tago/arrivals",params={"cityCode":"25","stopId":"S1"}).status_code == 401

@pytest.mark.auth_boundary
@pytest.mark.parametrize("role,expected",[("passenger",200),("driver",200),("admin",200),("camera",403)])
def test_role_scope(monkeypatch,role,expected):
    wire(monkeypatch,envelope([]))
    previous=dict(app.dependency_overrides)
    app.dependency_overrides[get_principal]=lambda:Principal("test-user",role)
    try:
        assert client.get("/diagnostics/tago/locations",params={"cityCode":"25","routeId":"R1"}).status_code == expected
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(previous)

def test_first_page_is_explicitly_partial(monkeypatch):
    wire(monkeypatch,envelope([{"routeid":"R1","arrtime":0}],total=120))
    data=client.get("/diagnostics/tago/arrivals",params={"cityCode":"25","stopId":"S1"}).json()
    assert data["truncated"] and data["totalCount"]==120
    assert data["records"][0]["arrivalSeconds"]==0
