"""Offline cache boundaries: timestamps are observations, not read time."""
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
import pytest
from fastapi import HTTPException
from app.services.bus_info_gateway_service import BusInfoGatewayService

NOW = datetime(2026, 11, 13, tzinfo=timezone.utc)
def payload(timestamp=NOW):
    item = dict(routeId="r", busNo="1", arrivalMinutes=2, lowFloor=True, congestion="UNKNOWN")
    if timestamp is not None:
        item["updatedAt"] = timestamp
    return dict(stopId="s", arrivals=[item])

def gateway(cached, *, failing=False, allow_cache=True):
    calls = []
    def fetch(stop):
        calls.append(stop)
        if failing:
            raise RuntimeError("offline")
        return payload()
    service = BusInfoGatewayService(firebase=SimpleNamespace(get=lambda _: cached),
        public_data_service=SimpleNamespace(get_arrivals=fetch, use_mock=False),
        clock=lambda: NOW, allow_cache=allow_cache)
    return service, calls

@pytest.mark.parametrize("age", [0, 29, 30])
def test_recent_cache_retains_observation_timestamp(age):
    timestamp = NOW - timedelta(seconds=age)
    service, calls = gateway(payload(timestamp))
    result = service.get_arrivals_with_source("s")
    assert result.source == "CACHE" and not calls
    assert result.response.arrivals[0].updatedAt == timestamp

@pytest.mark.parametrize("timestamp", [None, "bad", NOW.replace(tzinfo=None), NOW + timedelta(seconds=1), NOW-timedelta(seconds=31)])
def test_unknown_future_or_stale_cache_fetches_provider(timestamp):
    service, calls = gateway(payload(timestamp))
    assert service.get_arrivals_with_source("s").source == "PUBLIC_API"
    assert calls == ["s"]

@pytest.mark.parametrize("cached", [dict(stopId="s", arrivals=[]), dict(stopId="s"), {**payload(), "stopId":"other"}])
def test_empty_or_mismatched_cache_is_not_current_evidence(cached):
    service, calls = gateway(cached)
    service.get_arrivals("s")
    assert calls == ["s"]

def test_explicit_mode_bypasses_unverified_cache():
    service, calls = gateway(payload(), allow_cache=False)
    assert service.get_arrivals_with_source("s").source == "PUBLIC_API"
    assert calls == ["s"]

def test_stale_cache_never_returned_when_provider_fails():
    service, _ = gateway(payload(NOW-timedelta(days=1)), failing=True)
    with pytest.raises(HTTPException) as error:
        service.get_arrivals("s")
    assert error.value.status_code == 503

def test_missing_provider_timestamp_not_fabricated():
    service, _ = gateway(None)
    service.public_data_service.get_arrivals = lambda _: payload(None)
    with pytest.raises(HTTPException):
        service.get_arrivals("s")


def test_v3_live_mode_never_reads_unverified_cache():
    from app.api.routes import v3_bus
    for mode in (None, "live"):
        assert not v3_bus._gateway_for_request(live=True, mode=mode).allow_cache

def test_v3_arrival_preserves_timestamp_without_inventing_vehicle_identity():
    from app.api.routes.v3_bus import _from_gateway_response
    from app.schemas.bus_info import BusArrivalsResponse
    from app.schemas.v3 import FallbackSource
    result = _from_gateway_response(BusArrivalsResponse.model_validate(payload()),
        route_no=None, fallback_source=FallbackSource.PUBLIC_API)
    assert result.arrivals[0].updatedAt == NOW
    assert result.arrivals[0].busId is None
