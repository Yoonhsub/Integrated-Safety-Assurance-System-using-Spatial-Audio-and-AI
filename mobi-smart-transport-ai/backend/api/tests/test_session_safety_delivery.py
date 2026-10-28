"""Actual ASGI routes, Fake Admin/storage; never connects to Firebase."""
from datetime import datetime, timedelta, timezone
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.security import Principal, get_principal
from app.services import firebase_client as storage, session_safety_delivery as delivery
from app.services.firebase_client import FirebaseClient, FirebaseSettings
from app.services.safety_event_service import SafetyEventService
from app.services.v3_guidance_store import V3GuidanceStore
from app.api.routes import v3_guidance, ai_vision_events, safety_events

@pytest.fixture
def local(monkeypatch):
    fake = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    sessions = V3GuidanceStore()
    monkeypatch.setattr(storage, "firebase_client", fake)
    monkeypatch.setattr(delivery, "v3_guidance_store", sessions)
    monkeypatch.setattr(v3_guidance, "v3_guidance_store", sessions)
    monkeypatch.setattr(ai_vision_events, "_service", SafetyEventService(fake))
    monkeypatch.setattr(safety_events, "_service", SafetyEventService(fake))
    monkeypatch.setenv("APP_ENV", "test")
    monkeypatch.setenv("MOBI_SYNTHETIC_GUIDANCE", "true")
    caller = [Principal("owner", "passenger")]
    monkeypatch.setitem(app.dependency_overrides, get_principal, lambda: caller[0])
    with TestClient(app) as client:
        sid = client.post("/guidance/session", json={}).json()["sessionId"]
        baseline = client.get("/guidance/safety-events", params={"sessionId": sid}).json()
        yield client, caller, sid, baseline, sessions


def payload(**changes):
    value = dict(eventType="VISION_INTERPRETATION", source="ai_vision_mock", confidence=.71,
        timestamp=datetime.now(timezone.utc).isoformat(), metadata=dict(visionEventId="frame-one",
        reason="bus_door_visible", primaryClass="bus_door", riskLevel="info", modelProvider="mock"))
    value.update(changes)
    return value


def send(local, value=None, **params):
    client, caller, sid, baseline, _ = local
    caller[0] = Principal("admin", "admin")
    return client.post("/safety-events", params=dict(sessionId=sid,
        generation=baseline["generation"], **params), json=value or payload())


def read(local, **changes):
    client, caller, sid, baseline, _ = local
    caller[0] = Principal("owner", "passenger")
    params = dict(sessionId=sid, generation=baseline["generation"], after=baseline["cursor"])
    params.update(changes)
    return client.get("/guidance/safety-events", params=params)


def test_delivery_and_reconnect(local):
    assert send(local).status_code == 200
    result = read(local).json()
    assert len(result["events"]) == 1
    event = result["events"][0]
    assert event["synthetic"] is True and event["priority"] == "info"
    assert "검증용 합성" in event["message"] and 0 < event["validForSeconds"] <= 3
    assert read(local, after=result["cursor"]).json()["events"] == []
    client, _, sid, _, _ = local
    assert client.get("/guidance/safety-events", params={"sessionId": sid}).json()["events"] == []

@pytest.mark.parametrize("mutation", ["stale", "future", "wrong-class", "low", "duplicate", "reordered"])
def test_suppression(local, mutation):
    value = payload()
    if mutation == "stale": value["timestamp"] = (datetime.now(timezone.utc)-timedelta(seconds=10)).isoformat()
    if mutation == "future": value["timestamp"] = (datetime.now(timezone.utc)+timedelta(seconds=10)).isoformat()
    if mutation == "wrong-class": value["metadata"]["primaryClass"] = "bus"
    if mutation == "low": value["confidence"] = .1
    if mutation in {"duplicate", "reordered"}:
        assert send(local).status_code == 200
        baseline = read(local).json()
        local[3]["cursor"] = baseline["cursor"]
        if mutation == "reordered":
            value["metadata"]["visionEventId"] = "other"
            value["timestamp"] = (datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()
    assert send(local, value).status_code == 200
    assert read(local).json()["events"] == []

@pytest.mark.parametrize("attack", ["owner", "session", "generation", "closed", "reset", "synthetic-off", "source-owner"])
def test_scope_denial(local, monkeypatch, attack):
    client, caller, sid, base, sessions = local
    if attack == "synthetic-off":
        monkeypatch.delenv("MOBI_SYNTHETIC_GUIDANCE")
        assert send(local).status_code == 403
    elif attack == "source-owner": assert send(local, payload(userId="other")).status_code == 403
    elif attack == "generation":
        base["generation"] = "old"
        assert send(local).status_code == 409
    elif attack == "owner":
        caller[0] = Principal("other", "passenger")
        assert client.get("/guidance/safety-events", params={"sessionId": sid}).status_code == 403
    elif attack == "session": assert read(local, sessionId="other-session").status_code == 403
    elif attack == "closed":
        sessions._sessions[sid].vision_closed = True
        assert send(local).status_code == 403
        assert read(local).status_code == 403
    elif attack == "reset":
        assert client.post("/guidance/reset", json={"sessionId":sid,"event":"RESET","payload":{}}).status_code == 200
        assert send(local).status_code == 409
        assert read(local).json()["events"] == []


def test_passenger_cannot_publish(local):
    client, _, sid, base, _ = local
    assert client.post("/safety-events", params={"sessionId":sid,"generation":base["generation"]}, json=payload()).status_code == 403


def test_bound_ai_ingestion_and_no_event(local):
    from uuid import uuid4
    client, caller, sid, base, _ = local
    caller[0] = Principal("admin", "admin")
    query = dict(sessionId=sid, generation=base["generation"])
    value = dict(schemaVersion="1.0.0", status="event", source="image_file",
        eventId=str(uuid4()), frameId=str(uuid4()), capturedAt=datetime.now(timezone.utc).isoformat(),
        riskLevel="info", reason="bus_door_visible", primaryClass="bus_door", confidence=.71,
        message="Synthetic fixture", modelInfo=dict(provider="mock", name="fixture"))
    assert client.post("/ai-vision/events",params=query,json=value).status_code == 201
    assert len(read(local).json()["events"]) == 1
    base["cursor"] = read(local).json()["cursor"]
    caller[0] = Principal("admin", "admin")
    empty = dict(schemaVersion="1.0.0", status="no_event", source="image_file",
                 frameId=str(uuid4()), capturedAt=datetime.now(timezone.utc).isoformat())
    response = client.post("/ai-vision/events",params=query,json=empty)
    assert response.status_code == 200 and response.json()["stored"] is False
    assert read(local).json()["events"] == []


def test_unbound_and_other_session_never_delivered(local):
    client, caller, sid, base, _ = local
    caller[0] = Principal("admin", "admin")
    assert client.post("/safety-events",json=payload()).status_code == 200
    assert read(local).json()["events"] == []
    caller[0] = Principal("owner", "passenger")
    other = client.post("/guidance/session",json={}).json()["sessionId"]
    other_base = client.get("/guidance/safety-events",params={"sessionId":other}).json()
    assert send(local).status_code == 200
    caller[0] = Principal("owner", "passenger")
    assert client.get("/guidance/safety-events",params={"sessionId":other,
        "after":other_base["cursor"],"generation":other_base["generation"]}).json()["events"] == []
