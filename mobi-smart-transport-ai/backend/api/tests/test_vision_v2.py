"""HTTP auth boundary tests with mocked Firebase verifier, not real hardware."""
import json
from copy import deepcopy
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app import security
from app.api.routes import vision_v2
from app.main import app
from app.services import vision_binding_service as bindings
from app.services.v3_guidance_store import v3_guidance_store
from app.services.firebase_client import FirebaseClient, FirebaseSettings

pytestmark = pytest.mark.auth_boundary
ROOT = Path(__file__).resolve().parents[3]
LEASES = {}
ISSUES = {}


def issue_for(http, uid="alice", operation_id=None):
    auth = {"Authorization": "Bearer " + uid}
    registered = http.post("/guidance/vision-lease/operations", headers=auth, json={"operationId": operation_id or str(uuid4())})
    if registered.status_code != 201:
        return registered
    ticket = registered.json()
    issue = {k: ticket[k] for k in ("operationId", "startTicket", "version")}
    ISSUES[uid] = issue
    return http.post("/guidance/vision-lease", headers=auth, json=issue)


@pytest.fixture
def client(monkeypatch):
    previous = dict(app.dependency_overrides)
    app.dependency_overrides.clear()
    v3_guidance_store.clear()
    # Unit tests bypass environment setup only, never the authentication dependency.
    monkeypatch.setattr(bindings, "require_local_vision", lambda: None)
    monkeypatch.setattr(v3_guidance_store, "_persist", lambda _: None)
    monkeypatch.setattr(vision_v2, "vision_binding_service", bindings.VisionBindingService(storage=FirebaseClient(FirebaseSettings(None, None, None, None, True))))
    monkeypatch.setattr(security, "firebase_auth_app", lambda: object())

    def verify(token, **kwargs):
        assert kwargs["check_revoked"] and kwargs["clock_skew_seconds"] == 0
        errors = {"bad": security.auth.InvalidIdTokenError("invalid"),
                  "expired": security.auth.ExpiredIdTokenError("expired", None),
                  "revoked": security.auth.RevokedIdTokenError("revoked"),
                  "disabled": security.auth.UserDisabledError("disabled"),
                  "outage": RuntimeError("secret-error")}
        if token in errors:
            raise errors[token]
        return {"uid": token, "exp": time.time() + 3600, "auth_time": 1000, "mobi_role": "admin"}

    roles = {"producer": "vision_producer", "producer-b": "vision_producer",
             "alice": "passenger", "bob": "passenger", "driver": "driver", "admin": "admin"}
    monkeypatch.setattr(security.auth, "verify_id_token", verify)
    monkeypatch.setattr(security.auth, "get_user", lambda uid, **kw: SimpleNamespace(
        disabled=False, custom_claims={"mobi_role": roles[uid], "mobi_driver_id": "fleet-a"}))
    marker = security.current_principal.set(None)
    try:
        LEASES.clear()
        with TestClient(app) as http:
            for uid in ("alice", "bob"):
                issued = issue_for(http, uid)
                assert issued.status_code == 201
                LEASES[uid] = issued.json()["leaseId"]
            yield http
    finally:
        security.current_principal.reset(marker)
        app.dependency_overrides.clear()
        app.dependency_overrides.update(previous)
        v3_guidance_store.clear()


def headers(uid="admin"):
    value = {"Authorization": "Bearer " + uid}
    if uid in LEASES:
        value["X-Mobi-Vision-Lease"] = LEASES[uid]
    return value


def prepare(client, source="live"):
    session = client.post("/guidance/session", headers=headers("alice"), json={})
    assert session.status_code == 200
    sid = session.json()["sessionId"]
    assert client.put("/ai-vision/v2/cameras/camera-a", headers=headers(), json={
        "producerId": "producer", "sourceType": source}).status_code == 200
    response = client.post("/ai-vision/v2/bindings", headers=headers(), json={
        "cameraId": "camera-a", "sessionId": sid})
    assert response.status_code == 201
    binding = response.json()
    fixture = json.loads((ROOT / "ai_vision/pipelines/fixtures/mock_detection_results.json").read_text(encoding="utf-8"))["results"][0]
    fixture["source"] = {"live": "webcam", "replay": "video_file", "android_camera": "android_camera"}[source]
    fixture["capturedAt"] = datetime.now(timezone.utc).isoformat()
    payload = {k: binding[k] for k in ("bindingId", "cameraId", "producerId", "sessionId", "cameraEpoch", "sourceType")}
    payload.update(envelopeVersion="2.0.0", visionEventId=str(uuid4()), capturedAt=fixture["capturedAt"],
                   frameIndex=0, detectionResult=fixture)
    if source == "android_camera":
        payload["captureClock"] = "host_read"
        fixture["imageSize"] = {"width": 640, "height": 480}
    return payload


def send(client, payload, uid="producer"):
    return client.post("/ai-vision/v2/events", headers=headers(uid), json=payload)


@pytest.mark.parametrize("source", ["live", "replay"])
def test_valid_producer_no_storage_or_live_delivery(client, monkeypatch, source):
    payload = prepare(client, source)
    from app.services.safety_event_service import SafetyEventService
    monkeypatch.setattr(SafetyEventService, "create", lambda *a: pytest.fail("v2 must not store safety events"))
    response = send(client, payload)
    assert response.status_code == 202
    assert response.json()["accepted"] is True
    assert response.json()["stored"] is False
    assert response.json()["guidanceEligible"] is False
    assert response.json()["freshnessVerified"] is False
    assert client.get("/guidance/state", headers=headers("alice"), params={"sessionId": payload["sessionId"]}).json()["state"] == "IDLE"
    # Repeat submission is validated, never duplicated into the legacy event store.
    repeated = send(client, payload)
    assert repeated.status_code == 202
    assert repeated.json() == response.json()


@pytest.mark.parametrize("token,status", [(None, 401), ("bad", 401), ("expired", 401),
    ("revoked", 401), ("disabled", 401), ("outage", 503), ("alice", 403), ("driver", 403), ("admin", 403)])
def test_invalid_auth_cannot_submit(client, token, status):
    payload = prepare(client)
    response = client.post("/ai-vision/v2/events", json=payload, headers=headers(token) if token else {})
    assert response.status_code == status
    assert "secret-error" not in response.text


@pytest.mark.parametrize("field,value", [("producerId", "producer-b"), ("cameraId", "camera-b"),
    ("sessionId", "other-session"), ("bindingId", str(uuid4())), ("cameraEpoch", str(uuid4())),
    ("sourceType", "replay")])
def test_forged_scope_rejected(client, field, value):
    payload = prepare(client)
    payload[field] = value
    if field == "sourceType":
        payload["detectionResult"]["source"] = "video_file"
    assert send(client, payload).status_code == 403


def test_other_producer_and_passenger_session(client):
    payload = prepare(client)
    assert send(client, payload, "producer-b").status_code == 403
    bob = client.post("/guidance/session", headers=headers("bob"), json={}).json()["sessionId"]
    payload["sessionId"] = bob
    assert send(client, payload).status_code == 403
    assert client.post("/ai-vision/v2/bindings", headers=headers("bob"), json={
        "cameraId": "camera-a", "sessionId": bob}).status_code == 403


@pytest.mark.parametrize("operation", ["reset", "end", "reconnect", "revoke", "register", "restart"])
def test_old_bindings_invalidated(client, operation):
    payload = prepare(client)
    sid = payload["sessionId"]
    if operation == "reset":
        assert client.post("/guidance/reset", headers=headers("alice"), json={"sessionId": sid, "event": "RESET", "payload": {}}).status_code == 200
    elif operation == "end":
        marker = security.current_principal.set(security.Principal("alice", "passenger", auth_time=1000, vision_lease=LEASES["alice"]))
        try:
            v3_guidance_store.close_vision(sid)
        finally:
            security.current_principal.reset(marker)
    elif operation == "reconnect":
        assert client.post("/ai-vision/v2/bindings", headers=headers(), json={"cameraId": "camera-a", "sessionId": sid}).status_code == 201
    elif operation == "revoke":
        assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}", headers=headers()).status_code == 204
    elif operation == "register":
        assert client.put("/ai-vision/v2/cameras/camera-a", headers=headers(), json={"producerId": "producer-b", "sourceType": "live"}).status_code == 200
    else:
        vision_v2.vision_binding_service = bindings.VisionBindingService()
    assert send(client, payload).status_code == 403


def test_expiry_and_competing_bindings(client, monkeypatch):
    payload = prepare(client)
    with ThreadPoolExecutor(4) as pool:
        responses = list(pool.map(lambda _: client.post("/ai-vision/v2/bindings", headers=headers(),
            json={"cameraId": "camera-a", "sessionId": payload["sessionId"]}), range(4)))
    assert all(r.status_code == 201 for r in responses)
    outcomes = []
    for response in responses:
        candidate = dict(payload, bindingId=response.json()["bindingId"], cameraEpoch=response.json()["cameraEpoch"])
        result = send(client, candidate).status_code
        outcomes.append(result)
        if result == 202:
            active_candidate = candidate
    assert outcomes.count(202) == 1
    assert outcomes.count(403) == 3
    monkeypatch.setattr(bindings, "monotonic", lambda: float("inf"))
    assert send(client, active_candidate).status_code == 403


@pytest.mark.parametrize("change", ["class", "confidence", "bbox", "status", "time", "index", "extra"])
def test_detection_contract_remains_strict(client, change):
    payload = prepare(client)
    detection = payload["detectionResult"]
    if change == "class": detection["detections"][0]["className"] = "wrong"
    if change == "confidence": detection["detections"][0]["confidence"] = 1.1
    if change == "bbox": detection["detections"][0]["bbox"]["w"] = 1
    if change == "status": detection["status"] = "error"
    if change == "time": payload["capturedAt"] = "2026-10-13T00:00:00"
    if change == "index": payload["frameIndex"] = True
    if change == "extra": payload["userId"] = "bob"
    assert send(client, payload).status_code == 422


def test_legacy_endpoint_and_admin_management_stay_protected(client):
    for uid in ("producer", "alice", "driver"):
        assert client.post("/ai-vision/events", headers=headers(uid), json={}).status_code == 403
        assert client.put("/ai-vision/v2/cameras/a", headers=headers(uid), json={"producerId": uid, "sourceType": "live"}).status_code == 403


def test_production_v2_fails_closed(client, monkeypatch):
    payload = prepare(client)
    from app.local_emulator import validate_local_emulators
    def gate():
        try:
            validate_local_emulators()
        except ValueError:
            raise security.auth_error(503, "Local demo required")
    monkeypatch.setattr(bindings, "require_local_vision", gate)
    monkeypatch.setenv("APP_ENV", "production")
    assert send(client, payload).status_code == 503


def test_explicit_conversation_end_closes_binding(client, monkeypatch):
    from app.api.routes import v3_agent
    payload = prepare(client)
    monkeypatch.setattr(v3_agent, "classify_intent", lambda **kw: {"intent": "END_CONVERSATION", "destination": None})
    response = client.post("/agent/converse", headers=headers("alice"), json={
        "sessionId": payload["sessionId"], "utterance": "이번 대화를 마무리하겠습니다", "wakeWord": "자비스"})
    assert response.status_code == 200
    assert response.json()["intent"] == "END_CONVERSATION"
    assert send(client, payload).status_code == 403


def test_producer_cannot_manage_bindings_or_query_other_apis(client):
    payload = prepare(client)
    assert client.post("/ai-vision/v2/bindings", headers=headers("producer"), json={
        "cameraId": "camera-a", "sessionId": payload["sessionId"]}).status_code == 403
    assert client.get("/guidance/state", headers=headers("producer"), params={"sessionId": payload["sessionId"]}).status_code == 403
    assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}", headers=headers("producer")).status_code == 403


def test_actual_environment_guard_rejects_non_local(monkeypatch):
    # Exercise the production gate, not the mocked unit-test fixture.
    monkeypatch.setenv("APP_ENV", "production")
    with pytest.raises(Exception) as exc:
        bindings.require_local_vision()
    assert exc.value.status_code == 503


def test_shared_envelope_schemas_match_response(client):
    from jsonschema import Draft202012Validator, FormatChecker
    from referencing import Registry, Resource
    payload = prepare(client)
    base = ROOT / "packages/shared_contracts/api"
    schema = json.loads((base / "vision_v2.request.schema.json").read_text())
    schema["$id"] = "urn:mobi:vision-v2"
    detection = json.loads((base / "vision_detection.response.schema.json").read_text(encoding="utf-8"))
    registry = Registry().with_resource("vision_detection.response.schema.json", Resource.from_contents(detection))
    Draft202012Validator(schema, registry=registry, format_checker=FormatChecker()).validate(payload)
    response = send(client, payload)
    assert response.status_code == 202
    schema = json.loads((base / "vision_v2.response.schema.json").read_text())
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(response.json())


def test_missing_contract_fails_closed_without_import_failure(client, monkeypatch, tmp_path):
    from app.schemas import vision_v2 as schema
    payload = prepare(client)
    schema.detection_validator.cache_clear()
    monkeypatch.setattr(schema, "_SCHEMA", tmp_path / "absent.json")
    try:
        assert send(client, payload).status_code == 503
    finally:
        schema.detection_validator.cache_clear()


class FakeClock:
    def __init__(self):
        self.wall = datetime.now(timezone.utc)
        self.mono = 100.0

    def advance(self, seconds):
        self.wall += timedelta(seconds=seconds)
        self.mono += seconds


@pytest.fixture
def clock(client):
    clock = FakeClock()
    service = vision_v2.vision_binding_service
    service._utc_clock = lambda: clock.wall
    service._mono_clock = lambda: clock.mono
    service.policy = bindings.FreshnessPolicy(max_age=5, future_skew=1, observation_ttl=2, connection_timeout=4)
    return clock


def frame(payload, index, clock, age=0):
    value = json.loads(json.dumps(payload))
    timestamp = (clock.wall - timedelta(seconds=age)).isoformat()
    value.update(frameIndex=index, capturedAt=timestamp, visionEventId=str(uuid4()))
    value["detectionResult"].update(frameId=str(uuid4()), capturedAt=timestamp)
    return value


def state(client, uid="producer"):
    return client.get("/ai-vision/v2/cameras/camera-a/state", headers=headers(uid))


def test_sequence_duplicates_and_capture_order(client, clock):
    payload = prepare(client)
    ten = frame(payload, 10, clock)
    assert send(client, ten).status_code == 202
    assert send(client, ten).status_code == 202
    assert send(client, frame(payload, 9, clock)).status_code == 409
    assert send(client, frame(payload, 11, clock, age=1)).status_code == 409
    assert send(client, frame(payload, 11, clock)).status_code == 202
    value = state(client).json()
    assert value["lastFrameIndex"] == 11
    assert value["observationStatus"] == "observed"
    assert value["freshnessVerified"] is False


@pytest.mark.parametrize("age", [5, 100, -1.001, -100])
def test_stale_or_future_does_not_advance_observation(client, clock, age):
    payload = prepare(client)
    assert send(client, frame(payload, 1, clock)).status_code == 202
    before = state(client).json()
    assert send(client, frame(payload, 2, clock, age)).status_code == 409
    assert state(client).json() == before


@pytest.mark.parametrize("value", [None, "bad", "2026-10-13T00:00:00", 1234567890])
def test_timestamp_never_replaced_with_now(client, clock, value):
    payload = frame(prepare(client), 1, clock)
    payload["capturedAt"] = value
    assert send(client, payload).status_code == 422
    assert state(client).json()["lastFrameIndex"] is None


def test_future_within_skew_does_not_extend_ttl(client, clock):
    payload = frame(prepare(client), 1, clock, age=-1)
    payload["captureClock"] = "sensor"  # Client declaration cannot establish trust.
    assert send(client, payload).status_code == 202
    assert state(client).json()["freshnessVerified"] is False
    clock.advance(2)
    assert state(client).json()["observationStatus"] == "expired"


def test_expiry_loss_no_new_frames_and_reception(client, clock):
    payload = prepare(client)
    assert send(client, frame(payload, 1, clock)).status_code == 202
    clock.advance(2)
    value = state(client).json()
    assert value["observationStatus"] == "expired"
    assert value["connectionStatus"] == "connected"
    clock.advance(2)
    assert state(client).json()["connectionStatus"] == "lost"
    # A delayed lower frame cannot revalidate the expired observation.
    assert send(client, frame(payload, 0, clock)).status_code == 409
    assert state(client).json()["connectionStatus"] == "lost"
    assert send(client, frame(payload, 2, clock)).status_code == 202
    assert state(client).json()["observationStatus"] == "observed"


def test_partial_capture_budget_and_clock_jump_fail_closed(client, clock):
    payload = prepare(client)
    assert send(client, frame(payload, 1, clock, age=4)).status_code == 202
    clock.advance(1)
    assert state(client).json()["observationStatus"] == "expired"
    clock.wall -= timedelta(seconds=10)
    value = state(client).json()
    assert value["observationStatus"] == "expired" and value["connectionStatus"] == "lost"
    assert send(client, frame(payload, 2, clock)).status_code == 503


def test_waiting_camera_also_loses_connection(client, clock):
    prepare(client)
    clock.advance(4)
    assert state(client).json()["connectionStatus"] == "lost"
    assert state(client).json()["observationStatus"] == "unknown"


def test_replay_is_never_current_live_observation(client, clock):
    payload = prepare(client, "replay")
    assert send(client, frame(payload, 1, clock, age=100000)).status_code == 202
    clock.advance(100)
    value = state(client).json()
    assert value["observationStatus"] == "ineligible"
    assert value["connectionStatus"] == "replay"
    assert value["guidanceEligible"] is False and value["freshnessVerified"] is False
    assert send(client, frame(payload, 0, clock)).status_code == 409


@pytest.mark.parametrize("operation", ["revoke", "reconnect", "reset", "close", "expiry"])
def test_invalidation_cannot_leave_current_observation(client, clock, operation):
    payload = prepare(client)
    first = frame(payload, 1, clock)
    assert send(client, first).status_code == 202
    if operation == "revoke":
        assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}", headers=headers()).status_code == 204
    elif operation == "reconnect":
        r = client.post("/ai-vision/v2/bindings", headers=headers(), json={"cameraId": "camera-a", "sessionId": payload["sessionId"]})
        assert r.status_code == 201
        assert state(client).json()["lastFrameIndex"] is None
        fresh = dict(payload, bindingId=r.json()["bindingId"], cameraEpoch=r.json()["cameraEpoch"])
        assert send(client, frame(fresh, 0, clock)).status_code == 202
    elif operation == "reset":
        assert client.post("/guidance/reset", headers=headers("alice"), json={"sessionId": payload["sessionId"], "event": "RESET", "payload": {}}).status_code == 200
    elif operation == "close":
        marker = security.current_principal.set(security.Principal("alice", "passenger", auth_time=1000, vision_lease=LEASES["alice"]))
        try: v3_guidance_store.close_vision(payload["sessionId"])
        finally: security.current_principal.reset(marker)
    else:
        clock.advance(901)
    assert send(client, frame(payload, 2, clock)).status_code == 403
    assert send(client, first).status_code == 403
    if operation != "reconnect":
        value = state(client).json()
        assert value["connectionStatus"] == "closed"
        assert value["observationStatus"] == "unknown"


@pytest.mark.parametrize("indices", [(10, 11), (10, 10)])
def test_parallel_frames_have_atomic_watermark(client, clock, indices):
    payload = prepare(client)
    frames = [frame(payload, index, clock) for index in indices]
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda f: send(client, f).status_code, frames))
    assert state(client).json()["lastFrameIndex"] == max(indices)
    if indices == (10, 10):
        assert sorted(results) == [202, 409]
    else:
        assert results[1] == 202
        assert results[0] in (202, 409)


@pytest.mark.parametrize("operation", ["reconnect", "revoke", "close"])
def test_lifecycle_races_with_frame_acceptance(client, clock, operation):
    payload = prepare(client)
    def mutate():
        if operation == "reconnect":
            return client.post("/ai-vision/v2/bindings", headers=headers(), json={"cameraId": "camera-a", "sessionId": payload["sessionId"]}).status_code
        if operation == "revoke":
            return client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}", headers=headers()).status_code
        marker = security.current_principal.set(security.Principal("alice", "passenger", auth_time=1000, vision_lease=LEASES["alice"]))
        try: v3_guidance_store.close_vision(payload["sessionId"])
        finally: security.current_principal.reset(marker)
        return 200
    with ThreadPoolExecutor(2) as pool:
        event = pool.submit(send, client, frame(payload, 1, clock))
        mutation = pool.submit(mutate)
        assert mutation.result(timeout=10) in (200, 201, 204)
        assert event.result(timeout=10).status_code in (202, 403)
    assert send(client, frame(payload, 2, clock)).status_code == 403
    assert state(client).json()["lastFrameIndex"] is None


def test_status_query_authorization_and_failure_semantics(client, clock):
    payload = prepare(client)
    assert state(client, "producer-b").status_code == 403
    assert state(client, "alice").status_code == 403
    assert client.get("/ai-vision/v2/cameras/camera-a/state").status_code == 401
    value = frame(payload, 1, clock)
    value["detectionResult"].update(status="unavailable", detections=[], error={"code": "SOURCE_LOST", "message": "No frame"})
    assert send(client, value).status_code == 202
    assert state(client).json()["observationStatus"] == "unavailable"
    assert state(client).json()["connectionStatus"] == "lost"
    value = frame(payload, 2, clock)
    value["detectionResult"].update(status="error", detections=[], error={"code": "INFERENCE_FAILED", "message": "Failed"})
    assert send(client, value).status_code == 202
    assert state(client).json()["observationStatus"] == "error"
    assert state(client).json()["guidanceEligible"] is False


def test_invalid_server_timing_config_is_not_silently_defaulted(client, monkeypatch):
    payload = prepare(client)
    monkeypatch.setenv("MOBI_VISION_MAX_FRAME_AGE_SEC", "nan")
    assert send(client, payload).status_code == 503


def test_no_detection_is_not_a_safety_confirmation(client, clock):
    payload = frame(prepare(client), 1, clock)
    payload["detectionResult"]["detections"] = []
    assert send(client, payload).status_code == 202
    result = state(client).json()
    assert result["observationStatus"] == "no_detection"
    assert result["guidanceEligible"] is False and result["freshnessVerified"] is False


def test_rejected_old_frame_preserves_live_hold(client, clock, monkeypatch):
    from app.api.routes import v3_agent
    payload = prepare(client)
    for event in ("ROUTE_SELECTED", "WAITING_FOR_BUS"):
        r = client.post("/guidance/event", headers=headers(), json={"sessionId": payload["sessionId"],
            "event": event, "payload": {"routeNo": "502", "routeId": "mock-route-502", "stopId": "mock-stop-001", "targetBusId": "BUS_502_TERMINAL"}})
        assert r.status_code == 200
    assert send(client, frame(payload, 1, clock, age=100)).status_code == 409
    def forbidden_llm(**kw):
        pytest.fail("Live boarding safety must not delegate to an LLM")
    monkeypatch.setattr(v3_agent, "generate_dynamic_response", forbidden_llm)
    monkeypatch.setattr(v3_agent, "generate_optional_reply", forbidden_llm)
    r = client.post("/agent/converse", headers=headers("alice"), json={"sessionId": payload["sessionId"],
        "wakeWord": "자비스", "utterance": "자비스, 지금 앞에 온 버스 타도 돼?", "mode": "live"})
    assert r.status_code == 200
    assert r.json()["state"] == "WAITING_FOR_BUS"
    assert "확인하지 못했어요" in r.json()["message"]
    assert r.json()["ttsMode"] == "SAFETY_LOCAL"


@pytest.mark.parametrize("age", [5, 100, -1.001])
def test_first_frame_also_requires_current_server_window(client, clock, age):
    payload = prepare(client)
    response = send(client, frame(payload, 1, clock, age))
    assert response.status_code == 409
    assert state(client).json()["lastFrameIndex"] is None


def test_camera_state_shared_schema(client, clock):
    from jsonschema import Draft202012Validator, FormatChecker
    payload = prepare(client)
    assert send(client, frame(payload, 1, clock)).status_code == 202
    schema = json.loads((ROOT / "packages/shared_contracts/api/vision_v2.state.response.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(state(client).json())


def test_connection_loss_expires_observation_even_with_longer_ttl(client, clock):
    vision_v2.vision_binding_service.policy = bindings.FreshnessPolicy(max_age=10, future_skew=1, observation_ttl=8, connection_timeout=1)
    payload = prepare(client)
    assert send(client, frame(payload, 1, clock)).status_code == 202
    clock.advance(1)
    result = state(client).json()
    assert result["connectionStatus"] == "lost"
    assert result["observationStatus"] == "expired"


# Durable idempotency behavior. Memory storage is explicit fixture injection;
# actual RTDB/HTTP checks are run separately by the opt-in smoke.
def ledger_data():
    from app.services.vision_event_ledger import producer_path
    service = vision_v2.vision_binding_service
    return service.ledger._injected_storage.get(producer_path("producer"))


def test_same_event_receipt_survives_newer_frames_and_ttl(client, clock):
    payload = prepare(client)
    first = frame(payload, 10, clock)
    original = send(client, first)
    assert original.status_code == 202
    clock.advance(1)
    assert send(client, frame(payload, 11, clock)).status_code == 202
    before = state(client).json()
    clock.advance(5)
    repeated = send(client, first)
    assert repeated.status_code == 202 and repeated.json() == original.json()
    value = state(client).json()
    assert value["lastFrameIndex"] == 11
    assert value["lastReceivedAt"] == before["lastReceivedAt"]
    assert value["connectionStatus"] == "lost"
    assert len(ledger_data()["events"]) == 2


def test_concurrent_identical_events_commit_one_receipt(client, clock):
    value = frame(prepare(client), 10, clock)
    with ThreadPoolExecutor(4) as pool:
        responses = list(pool.map(lambda _: send(client, value), range(8)))
    assert all(r.status_code == 202 for r in responses)
    assert all(r.json() == responses[0].json() for r in responses)
    assert len(ledger_data()["events"]) == 1
    assert len(ledger_data()["streams"]) == 1
    assert state(client).json()["lastFrameIndex"] == 10


def test_conflict_and_json_field_order_are_distinct(client, clock):
    value = frame(prepare(client), 1, clock)
    original = send(client, value)
    changed = json.loads(json.dumps(value))
    changed["detectionResult"]["modelInfo"]["name"] = "different-model"
    assert send(client, changed).status_code == 409
    def reorder(v):
        if isinstance(v, dict): return {k: reorder(v[k]) for k in reversed(list(v))}
        if isinstance(v, list): return [reorder(x) for x in v]
        return v
    assert send(client, reorder(value)).json() == original.json()
    # Same event in equivalent timezone notation is the same capture instant.
    equivalent = json.loads(json.dumps(value))
    dt = datetime.fromisoformat(value["capturedAt"]).astimezone(timezone(timedelta(hours=9)))
    equivalent["capturedAt"] = dt.isoformat()
    equivalent["detectionResult"]["capturedAt"] = dt.isoformat()
    assert send(client, equivalent).json() == original.json()
    another = dict(value, visionEventId=str(uuid4()))
    assert send(client, another).status_code == 409
    assert len(ledger_data()["events"]) == 1


def test_other_producer_same_event_id_has_separate_scope(client, clock):
    first = frame(prepare(client), 1, clock)
    assert send(client, first).status_code == 202
    assert client.put("/ai-vision/v2/cameras/camera-b", headers=headers(), json={"producerId": "producer-b", "sourceType": "live"}).status_code == 200
    binding = client.post("/ai-vision/v2/bindings", headers=headers(), json={"cameraId": "camera-b", "sessionId": first["sessionId"]}).json()
    second = dict(first, producerId="producer-b", cameraId="camera-b", bindingId=binding["bindingId"], cameraEpoch=binding["cameraEpoch"])
    assert send(client, second, "producer-b").status_code == 202
    from app.services.vision_event_ledger import producer_path
    storage = vision_v2.vision_binding_service.ledger._injected_storage
    assert len(storage.get(producer_path("producer-b"))["events"]) == 1
    assert len(ledger_data()["events"]) == 1


@pytest.mark.parametrize("after_commit", [False, True])
def test_storage_failure_before_and_after_commit_fails_closed(client, clock, monkeypatch, after_commit):
    value = frame(prepare(client), 10, clock)
    storage = vision_v2.vision_binding_service.ledger._injected_storage
    transaction = storage.transaction
    def fail(path, transform):
        if after_commit: transaction(path, transform)
        raise RuntimeError("internal-sensitive-storage-error")
    monkeypatch.setattr(storage, "transaction", fail)
    response = send(client, value)
    assert response.status_code == 503
    assert "internal-sensitive" not in response.text
    assert state(client).json()["lastFrameIndex"] is None
    monkeypatch.setattr(storage, "transaction", transaction)
    retry = send(client, value)
    assert retry.status_code == 202
    data = ledger_data()
    assert len(data["events"]) == 1
    assert data["streams"][value["bindingId"]]["frameIndex"] == 10
    if after_commit:
        # A duplicate must not fabricate a new observation after unknown commit.
        assert state(client).json()["lastFrameIndex"] is None
    assert send(client, frame(value, 9, clock)).status_code == 409
    assert send(client, frame(value, 11, clock)).status_code == 202


def test_service_restart_keeps_receipt_but_never_restores_binding(client, clock):
    first = frame(prepare(client), 10, clock)
    assert send(client, first).status_code == 202
    storage = vision_v2.vision_binding_service.ledger._injected_storage
    vision_v2.vision_binding_service = bindings.VisionBindingService(storage=storage)
    assert send(client, first).status_code == 403
    assert client.put("/ai-vision/v2/cameras/camera-a", headers=headers(), json={"producerId": "producer", "sourceType": "live"}).status_code == 200
    binding = client.post("/ai-vision/v2/bindings", headers=headers(), json={"cameraId": "camera-a", "sessionId": first["sessionId"]}).json()
    changed = dict(first, bindingId=binding["bindingId"], cameraEpoch=binding["cameraEpoch"])
    assert send(client, changed).status_code == 409
    from app.services.vision_event_ledger import producer_path
    assert len(storage.get(producer_path("producer"))["events"]) == 1


def test_existing_receipt_does_not_bypass_current_account_role(client, clock, monkeypatch):
    value = frame(prepare(client), 1, clock)
    assert send(client, value).status_code == 202
    monkeypatch.setattr(security.auth, "get_user", lambda *a, **k: SimpleNamespace(
        disabled=False, custom_claims={"mobi_role": "passenger"}))
    assert send(client, value).status_code == 403
    assert len(ledger_data()["events"]) == 1

@pytest.mark.parametrize('source', ['live','replay'])
def test_owned_observation_preview_and_duplicate_ttl(client, clock, source):
    payload=frame(prepare(client,source),0,clock)
    payload['detectionResult']['detections'][0].update(classId='bus', className='버스')
    response=send(client,payload)
    assert response.status_code==202 and response.json()['stored'] is False
    path=f"/ai-vision/v2/sessions/{payload['sessionId']}/observations"
    first=client.get(path,headers=headers('alice'))
    assert first.status_code==200
    item=first.json()['observations'][0]
    assert item['observedClasses']==['bus'] and item['state']=='available'
    assert item['sourceType']==source and item['guidanceEligible'] is False
    assert client.get(path).status_code==401
    assert client.get(path,headers=headers('bob')).status_code==403
    assert client.get(path,headers=headers('driver')).status_code==403
    clock.advance(1)
    assert send(client,payload).json()==response.json()
    item=client.get(path,headers=headers('alice')).json()['observations'][0]
    assert item['validForSeconds']==1 and item['receivedAt']==first.json()['observations'][0]['receivedAt']
    clock.advance(1)
    item=client.get(path,headers=headers('alice')).json()['observations'][0]
    assert item['state']=='expired' and item['observedClasses']==[]
    clock.advance(2)
    assert client.get(path,headers=headers('alice')).json()['observations'][0]['state']=='lost'


def test_preview_revoke_reset_close_and_reverse_order(client,clock):
    payload=frame(prepare(client),10,clock)
    assert send(client,payload).status_code==202
    path=f"/ai-vision/v2/sessions/{payload['sessionId']}/observations"
    assert send(client,frame(payload,9,clock)).status_code==409
    assert client.get(path,headers=headers('alice')).json()['observations'][0]['frameIndex']==10
    assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}",headers=headers()).status_code==204
    assert client.get(path,headers=headers('alice')).json()['observations']==[]
    assert send(client,payload).status_code==403
    from app.security import current_principal,Principal
    token=current_principal.set(Principal('alice','passenger',auth_time=1000,vision_lease=LEASES['alice']))
    try: v3_guidance_store.close_vision(payload['sessionId'])
    finally: current_principal.reset(token)
    assert client.get(path,headers=headers('alice')).status_code==403


def test_door_detection_is_not_presented_as_pretrained_model_capability(client,clock):
    payload=frame(prepare(client,'replay'),0,clock)
    payload['detectionResult']['detections']=[dict(payload['detectionResult']['detections'][0],classId='bus_door',className='버스 문')]
    assert send(client,payload).status_code==202
    item=client.get(f"/ai-vision/v2/sessions/{payload['sessionId']}/observations",headers=headers('alice')).json()['observations'][0]
    assert item['observedClasses']==[]
    assert '승차' not in item['message']

@pytest.mark.parametrize('recognized', [True,False])
def test_verified_tflite_profile_door_preview_remains_observation_only(client,clock,recognized):
    payload=frame(prepare(client,'replay'),0,clock)
    payload['detectionResult']['modelInfo']={'provider':'tflite','name':'yolo11n_bus_door_v1_float32',
        'version':'0d2b911','identifier':'sha256:7178a76b3abaa83bfac0ad9c5b1ea40627560d6aa0e05587b335950a1bffaa85' if recognized else 'unknown'}
    payload['detectionResult']['detections']=[dict(payload['detectionResult']['detections'][0],classId='bus_door',className='버스 문')]
    response=send(client,payload)
    assert response.status_code==202
    assert all(response.json()[k] is False for k in ('stored','guidanceEligible','freshnessVerified'))
    path=f"/ai-vision/v2/sessions/{payload['sessionId']}/observations"
    item=client.get(path,headers=headers('alice')).json()['observations'][0]
    assert item['observedClasses']==(['bus_door'] if recognized else [])
    assert '승차' not in item['message']
    clock.advance(3)
    assert client.get(path,headers=headers('alice')).json()['observations'][0]['observedClasses']==[]


# Vision login Lease acceptance: never client-selected, never a token substitute.
def new_lease(client, monkeypatch=None, login_time=None):
    if login_time is not None:
        old = security.auth.verify_id_token
        def verify(token, **kwargs):
            claims = old(token, **kwargs)
            if claims["uid"] == "alice":
                claims["auth_time"] = login_time
            return claims
        monkeypatch.setattr(security.auth, "verify_id_token", verify)
    response = issue_for(client)
    assert response.status_code == 201
    LEASES["alice"] = response.json()["leaseId"]
    return response.json()


def owned_preview(client, payload, expected=200):
    response = client.get(f"/ai-vision/v2/sessions/{payload['sessionId']}/observations", headers=headers("alice"))
    assert response.status_code == expected
    if expected != 200:
        assert "observations" not in response.json() and "detections" not in response.text
    return response


def test_lease_relogin_denies_old_transmission_and_preview(client, monkeypatch):
    payload = prepare(client)
    assert send(client, payload).status_code == 202
    before = ledger_data()
    lease_a = LEASES["alice"]
    new_lease(client, monkeypatch, 2000)
    assert LEASES["alice"] != lease_a
    assert send(client, payload).status_code == 403
    assert ledger_data() == before
    owned_preview(client, payload, 403)
    old = headers("alice");old["X-Mobi-Vision-Lease"] = lease_a
    assert client.get("/guidance/vision-lease", headers=old).status_code == 403
    # New session with the active lease still needs explicit administrator binding.
    sid = client.post("/guidance/session", headers=headers("alice"), json={}).json()["sessionId"]
    forged = dict(payload, sessionId=sid)
    assert send(client, forged).status_code == 403
    rebound = client.post("/ai-vision/v2/bindings", headers=headers(), json={"cameraId":"camera-a","sessionId":sid}).json()
    candidate = dict(payload, **{k:rebound[k] for k in ("bindingId","cameraEpoch","sessionId")}, visionEventId=str(uuid4()))
    assert send(client, candidate).status_code == 202
    assert owned_preview(client, candidate).json()["observations"][0]["visionEventId"] == candidate["visionEventId"]


def test_lease_refresh_same_auth_time_keeps_id_and_deadline(client):
    payload = prepare(client)
    first = client.get("/guidance/vision-lease", headers=headers("alice")).json()
    # Fixture reissues exp on each verification; immutable auth_time is unchanged.
    second = client.get("/guidance/vision-lease", headers=headers("alice")).json()
    assert second == first and send(client, payload).status_code == 202


@pytest.mark.parametrize("mode", ["logout", "expiry"])
def test_lease_revoke_expiry_blocks_reads_and_writes(client, mode, monkeypatch):
    payload = prepare(client)
    assert send(client, payload).status_code == 202
    before = ledger_data()
    if mode == "logout":
        assert client.delete("/guidance/vision-lease", headers=headers("alice")).status_code == 204
    else:
        monkeypatch.setattr(v3_guidance_store, "_lease_clock", lambda: float("inf"))
    assert send(client, dict(payload, frameIndex=1, visionEventId=str(uuid4()))).status_code == 403
    assert ledger_data() == before
    owned_preview(client, payload, 403)
    assert state(client).json()["lastFrameIndex"] is None


@pytest.mark.parametrize("body", [{"leaseId":"chosen"}, {"ownerUid":"bob"}, {"ttlSeconds":999999}])
def test_lease_client_cannot_choose_scope(client, body):
    assert client.post("/guidance/vision-lease", json=body, headers=headers("alice")).status_code == 422


@pytest.mark.parametrize("uid,expected", [(None,401),("bad",401),("producer",403),("admin",403),("bob",403)])
def test_lease_auth_and_cross_owner_denied(client, uid, expected):
    value = headers(uid) if uid else {}
    value["X-Mobi-Vision-Lease"] = LEASES["alice"]
    response = client.get("/guidance/vision-lease", headers=value)
    assert response.status_code == expected
    assert "leaseId" not in response.json() and "observations" not in response.text


def test_lease_header_required_and_cannot_attach_old_session(client):
    payload = prepare(client)
    assert client.get(f"/ai-vision/v2/sessions/{payload['sessionId']}/observations", headers={"Authorization":"Bearer alice"}).status_code == 403
    # An unleased normal Guidance session remains supported but cannot bind Vision.
    sid = client.post("/guidance/session", headers={"Authorization":"Bearer alice"}, json={}).json()["sessionId"]
    assert client.post("/ai-vision/v2/bindings", headers=headers(), json={"cameraId":"camera-a","sessionId":sid}).status_code == 403


def test_lease_missing_login_time_fails_closed_without_breaking_normal_guidance(client, monkeypatch):
    old = security.auth.verify_id_token
    def verify(token, **kw):
        value=old(token, **kw);value.pop("auth_time",None);return value
    monkeypatch.setattr(security.auth,"verify_id_token",verify)
    auth={"Authorization":"Bearer alice"}
    assert client.post("/guidance/vision-lease", headers=auth, json=ISSUES["alice"]).status_code == 401
    assert client.post("/guidance/session", headers=auth, json={}).status_code == 200


def test_lease_older_login_cannot_replace_newer(client,monkeypatch):
    new_lease(client,monkeypatch,2000)
    current=LEASES["alice"]
    old=security.auth.verify_id_token
    def stale(token,**kw):
        value=old(token,**kw);value["auth_time"]=1000;return value
    monkeypatch.setattr(security.auth,"verify_id_token",stale)
    assert issue_for(client).status_code == 403
    assert v3_guidance_store._vision_leases["alice"].lease_id==current


def test_lease_logout_cannot_revoke_new_login_with_old_header(client):
    old=LEASES["alice"];new_lease(client)
    assert client.delete("/guidance/vision-lease",headers={"Authorization":"Bearer alice","X-Mobi-Vision-Lease":old}).status_code==403
    assert client.get("/guidance/vision-lease",headers=headers("alice")).status_code==200


def test_lease_reset_keeps_lease_but_discards_old_generation(client):
    payload=prepare(client);lease=LEASES["alice"]
    assert send(client,payload).status_code==202
    assert client.post("/guidance/reset",headers=headers("alice"),json={"sessionId":payload["sessionId"],"event":"RESET","payload":{}}).status_code==200
    assert client.get("/guidance/vision-lease",headers=headers("alice")).json()["leaseId"]==lease
    assert send(client,payload).status_code==403
    assert owned_preview(client,payload).json()["observations"]==[]


def test_lease_expiry_without_logout_bounds_old_binding(client,monkeypatch):
    payload=prepare(client);before=ledger_data()
    clock=v3_guidance_store._lease_clock
    monkeypatch.setattr(v3_guidance_store,"_lease_clock",lambda:clock()+901)
    assert send(client,payload).status_code==403
    assert ledger_data()==before
    owned_preview(client,payload,403)


def test_lease_rotation_linearizes_with_memory_commit(client,monkeypatch):
    from threading import Event
    payload=prepare(client);service=vision_v2.vision_binding_service
    entered,release,rotation_started,rotation_done=Event(),Event(),Event(),Event()
    storage=service.ledger._injected_storage;original=storage.transaction
    def paused(path,transform):
        entered.set();assert release.wait(5);return original(path,transform)
    monkeypatch.setattr(storage,"transaction",paused)
    def rotate():
        rotation_started.set();result=issue_for(client);rotation_done.set();return result
    with ThreadPoolExecutor(2) as pool:
        pending=pool.submit(send,client,payload);assert entered.wait(5)
        rotated=pool.submit(rotate);assert rotation_started.wait(5)
        try:assert not rotation_done.wait(.1)
        finally:release.set()
        assert pending.result(5).status_code==202
        answer=rotated.result(5);assert answer.status_code==201;LEASES["alice"]=answer.json()["leaseId"]
    assert send(client,payload).status_code==403
    owned_preview(client,payload,403)
    assert all(not record.safety_items for record in v3_guidance_store._sessions.values())


def test_lease_rotation_after_auth_before_accept_has_no_commit(client,monkeypatch):
    payload=prepare(client);service=vision_v2.vision_binding_service;original=service.accept
    from threading import Event
    entered,release=Event(),Event()
    def paused(value):
        entered.set();assert release.wait(5);return original(value)
    monkeypatch.setattr(service,"accept",paused)
    with ThreadPoolExecutor(1) as pool:
        pending=pool.submit(send,client,payload);assert entered.wait(5)
        try:new_lease(client)
        finally:release.set()
        assert pending.result(5).status_code==403
    assert ledger_data() is None
    owned_preview(client,payload,403)



def test_lease_authenticated_renewal_preserves_id_and_binding(client,monkeypatch):
    payload=prepare(client)
    first=client.get("/guidance/vision-lease",headers=headers("alice")).json()
    clock=v3_guidance_store._lease_clock
    monkeypatch.setattr(v3_guidance_store,"_lease_clock",lambda:clock()+10)
    answer=client.put("/guidance/vision-lease",headers=headers("alice"),json={})
    assert answer.status_code==200 and answer.json()["leaseId"]==first["leaseId"]
    assert answer.json()["createdAt"]==first["createdAt"]
    assert v3_guidance_store._vision_leases['alice'].deadline>clock()+900
    assert send(client,payload).status_code==202


def test_lease_expired_cannot_renew_and_logout_is_idempotent(client,monkeypatch):
    first=LEASES['alice'];clock=v3_guidance_store._lease_clock
    monkeypatch.setattr(v3_guidance_store,'_lease_clock',lambda:clock()+901)
    assert client.put('/guidance/vision-lease',headers=headers('alice'),json={}).status_code==403
    assert client.delete('/guidance/vision-lease',headers=headers('alice')).status_code==204
    assert client.delete('/guidance/vision-lease',headers=headers('alice')).status_code==204
    assert v3_guidance_store._vision_leases['alice'].lease_id==first



def test_lease_fingerprint_receipt_scope_cannot_drop_lease(client):
    payload=prepare(client)
    assert send(client,payload).status_code==202
    service=vision_v2.vision_binding_service
    from app.services.vision_event_ledger import producer_path
    raw=ledger_data()
    next(iter(raw['events'].values())).pop('passengerLeaseId')
    service.ledger._injected_storage.set(producer_path('producer'),raw)
    assert send(client,payload).status_code==503
    assert ledger_data()==raw


def test_lease_transaction_expiry_validator_is_side_effect_free(client,monkeypatch):
    payload=prepare(client);service=vision_v2.vision_binding_service
    session=v3_guidance_store._sessions[payload['sessionId']];generation=session.vision_generation
    lease=v3_guidance_store._vision_leases['alice']
    def transaction(path,transform):
        monkeypatch.setattr(v3_guidance_store,'_lease_clock',lambda:lease.deadline+1)
        try:transform(None)
        finally:assert session.vision_generation==generation and not session.vision_closed
    monkeypatch.setattr(service.ledger._injected_storage,'transaction',transaction)
    assert send(client,payload).status_code==403
    assert ledger_data() is None
    owned_preview(client,payload,403)


# Server registration order is the authority, never UUID/time from the client.
def start_operation(client, uid="alice", operation_id=None, **extra):
    return client.post("/guidance/vision-lease/operations", headers={"Authorization":"Bearer "+uid},
                       json={"operationId":operation_id or str(uuid4()), **extra})


def issue_ticket(client, ticket, uid="alice"):
    return client.post("/guidance/vision-lease", headers={"Authorization":"Bearer "+uid},
                       json={k:ticket[k] for k in ("operationId","startTicket","version")})


def lease_state_snapshot():
    from copy import deepcopy
    service=vision_v2.vision_binding_service
    lease=v3_guidance_store._vision_leases.get("alice")
    return (dict(lease.__dict__) if lease else None,
            {sid:(r.vision_closed,r.vision_generation,r.vision_lease_id) for sid,r in v3_guidance_store._sessions.items()},
            deepcopy(service._bindings),deepcopy(service._observations),ledger_data())


def test_ticket_registration_retry_does_not_advance_version_or_revoke(client):
    payload=prepare(client);assert send(client,payload).status_code==202
    before=lease_state_snapshot();key=str(uuid4())
    first=start_operation(client,operation_id=key);assert first.status_code==201
    version=v3_guidance_store._vision_start_versions['alice']
    second=start_operation(client,operation_id=key)
    assert second.status_code==201 and second.json()==first.json()
    assert v3_guidance_store._vision_start_versions['alice']==version
    assert lease_state_snapshot()==before


def test_ticket_concurrent_registration_and_issue_once(client):
    key=str(uuid4());before=v3_guidance_store._vision_start_versions['alice']
    with ThreadPoolExecutor(8) as pool:
        tickets=list(pool.map(lambda _:start_operation(client,operation_id=key),range(8)))
    assert all(t.status_code==201 and t.json()==tickets[0].json() for t in tickets)
    assert v3_guidance_store._vision_start_versions['alice']==before+1
    ticket=tickets[0].json()
    with ThreadPoolExecutor(8) as pool:
        issued=list(pool.map(lambda _:issue_ticket(client,ticket),range(8)))
    assert all(x.status_code==201 and x.json()==issued[0].json() for x in issued)
    lease=v3_guidance_store._vision_leases['alice'];assert lease.version==ticket['version']
    op=v3_guidance_store._vision_operations[('alice',key)]
    assert op.status=='issued' and op.receipt is not None
    assert not {'leaseId','startTicket','token','refreshToken','authorization'}.intersection(op.receipt)


def test_ticket_same_key_different_payload_conflict_preserves_binding(client):
    payload=prepare(client);before=lease_state_snapshot();key=str(uuid4())
    ticket=start_operation(client,operation_id=key).json()
    different=start_operation(client,operation_id=key,expectedActiveVersion=ticket['activeVersion'])
    assert different.status_code==409 and lease_state_snapshot()==before
    issued=issue_ticket(client,ticket);assert issued.status_code==201
    after=lease_state_snapshot();wrong=dict(ticket,version=ticket['version']+1)
    assert issue_ticket(client,wrong).status_code==409 and lease_state_snapshot()==after


def test_ticket_active_binding_survives_duplicate_and_pending_start(client):
    payload=prepare(client);assert send(client,payload).status_code==202
    old_issue=ISSUES['alice'];before=lease_state_snapshot()
    pending=start_operation(client).json()
    replay=issue_ticket(client,old_issue)
    assert replay.status_code==201 and replay.json()['leaseId']==LEASES['alice']
    assert lease_state_snapshot()==before
    issued=issue_ticket(client,pending);assert issued.status_code==201
    LEASES['alice']=issued.json()['leaseId']
    assert send(client,payload).status_code==403
    owned_preview(client,payload,403)


def test_ticket_late_first_old_operation_and_old_receipt_cannot_replace(client):
    a=start_operation(client).json();b=start_operation(client).json()
    before=lease_state_snapshot()
    assert issue_ticket(client,a).status_code==410 and lease_state_snapshot()==before
    granted=issue_ticket(client,b);assert granted.status_code==201
    after=lease_state_snapshot()
    assert issue_ticket(client,a).status_code==410 and lease_state_snapshot()==after
    # A newer committed operation retires the previous committed receipt too.
    c=start_operation(client).json();assert issue_ticket(client,c).status_code==201
    after=lease_state_snapshot()
    assert issue_ticket(client,b).status_code==410 and lease_state_snapshot()==after
    assert start_operation(client,operation_id=b['operationId']).status_code==410


@pytest.mark.parametrize('mode',['logout','expiry','ticket-expiry'])
def test_ticket_terminal_replay_never_revives(client,monkeypatch,mode):
    ticket=start_operation(client).json()
    if mode!='ticket-expiry':
        response=issue_ticket(client,ticket);assert response.status_code==201;LEASES['alice']=response.json()['leaseId']
    if mode=='logout':
        assert client.delete('/guidance/vision-lease',headers=headers('alice')).status_code==204
    else:
        clock=v3_guidance_store._lease_clock
        monkeypatch.setattr(v3_guidance_store,'_lease_clock',lambda:clock()+901)
    before=lease_state_snapshot()
    assert issue_ticket(client,ticket).status_code in (403,410)
    assert lease_state_snapshot()==before
    assert start_operation(client,operation_id=ticket['operationId']).status_code==410


def test_ticket_logout_fences_pending_but_delayed_duplicate_logout_does_not(client):
    old_header=headers('alice');pending=start_operation(client).json()
    assert client.delete('/guidance/vision-lease',headers=old_header).status_code==204
    assert issue_ticket(client,pending).status_code==410
    new=start_operation(client).json()
    assert client.delete('/guidance/vision-lease',headers=old_header).status_code==204
    assert issue_ticket(client,new).status_code==201


def test_ticket_scope_token_refresh_and_new_auth_context(client,monkeypatch):
    ticket=start_operation(client).json();before=lease_state_snapshot()
    assert issue_ticket(client,ticket,'bob').status_code==403
    assert lease_state_snapshot()==before
    # Same UID, different verified auth_time cannot recover old operation.
    original=security.auth.verify_id_token
    def new_auth(token,**kw):
        value=original(token,**kw)
        if value['uid']=='alice':value['auth_time']=2000
        return value
    monkeypatch.setattr(security.auth,'verify_id_token',new_auth)
    assert issue_ticket(client,ticket).status_code==403
    assert start_operation(client,operation_id=ticket['operationId']).status_code==403
    assert lease_state_snapshot()==before
    newer=start_operation(client).json();first=issue_ticket(client,newer)
    second=issue_ticket(client,newer)
    assert first.status_code==second.status_code==201 and first.json()==second.json()


def test_ticket_cross_uid_same_key_is_scoped_and_cannot_recover_other_receipt(client):
    key=str(uuid4());a=start_operation(client,operation_id=key).json();b=start_operation(client,'bob',key).json()
    assert a['startTicket']!=b['startTicket']
    assert issue_ticket(client,a,'bob').status_code==403
    assert issue_ticket(client,b,'alice').status_code==403
    assert issue_ticket(client,a).status_code==201
    assert issue_ticket(client,b,'bob').status_code==201


def test_ticket_receipt_cleanup_keeps_tombstone_and_healthy_renewed_lease(client,monkeypatch):
    payload=prepare(client);assert send(client,payload).status_code==202
    issue=ISSUES['alice'];clock=v3_guidance_store._lease_clock
    monkeypatch.setattr(v3_guidance_store,'_lease_clock',lambda:clock()+100)
    assert client.put('/guidance/vision-lease',headers=headers('alice'),json={}).status_code==200
    monkeypatch.setattr(v3_guidance_store,'_lease_clock',lambda:clock()+901)
    before=lease_state_snapshot();version=v3_guidance_store._vision_start_versions['alice']
    assert issue_ticket(client,issue).status_code==410
    assert start_operation(client,operation_id=issue['operationId']).status_code==410
    assert lease_state_snapshot()==before and v3_guidance_store._vision_start_versions['alice']==version
    row=v3_guidance_store._vision_operations[('alice',issue['operationId'])]
    assert row.receipt is None and row.status=='receipt-expired'
    # Receipt cleanup is not Lease revocation; normal owner GET still works.
    assert client.get('/guidance/vision-lease',headers=headers('alice')).status_code==200


def test_ticket_session_close_replay_does_not_reopen_guidance(client):
    payload=prepare(client);assert send(client,payload).status_code==202
    marker=security.current_principal.set(security.Principal('alice','passenger',auth_time=1000,vision_lease=LEASES['alice']))
    try:v3_guidance_store.close_vision(payload['sessionId'])
    finally:security.current_principal.reset(marker)
    before=lease_state_snapshot()
    assert issue_ticket(client,ISSUES['alice']).status_code==201
    assert lease_state_snapshot()==before
    assert send(client,payload).status_code==403
    owned_preview(client,payload,403)


def test_ticket_internal_issue_exception_rolls_back_every_state(client,monkeypatch):
    payload=prepare(client);assert send(client,payload).status_code==202
    ticket=start_operation(client).json();before=lease_state_snapshot();old=v3_guidance_store._invalidate_lease
    def fail(lease,state):
        old(lease,state)
        raise RuntimeError('injected after invalidation, no secrets')
    monkeypatch.setattr(v3_guidance_store,'_invalidate_lease',fail)
    response=issue_ticket(client,ticket)
    assert response.status_code==503 and lease_state_snapshot()==before
    op=v3_guidance_store._vision_operations[('alice',ticket['operationId'])]
    assert op.status=='prepared' and op.receipt is None
    monkeypatch.setattr(v3_guidance_store,'_invalidate_lease',old)
    assert issue_ticket(client,ticket).status_code==201


def test_ticket_internal_registration_exception_keeps_version_and_active_state(client,monkeypatch):
    first=start_operation(client).json();before=lease_state_snapshot();version=v3_guidance_store._vision_start_versions['alice'];old=v3_guidance_store._operation_response
    monkeypatch.setattr(v3_guidance_store,'_operation_response',lambda _:(_ for _ in ()).throw(RuntimeError('injected')))
    assert start_operation(client).status_code==503
    assert lease_state_snapshot()==before and v3_guidance_store._vision_start_versions['alice']==version
    row=v3_guidance_store._vision_operations[('alice',first['operationId'])];assert row.status=='prepared'
    monkeypatch.setattr(v3_guidance_store,'_operation_response',old)
    assert issue_ticket(client,first).status_code==201


def test_ticket_unregistered_and_wrong_auth_no_receipt_disclosure(client):
    ticket={'operationId':str(uuid4()),'version':1,'startTicket':'A'*43}
    before=lease_state_snapshot()
    for uid,expected in [('alice',403),('bad',401),('producer',403)]:
        response=issue_ticket(client,ticket,uid)
        assert response.status_code==expected and 'leaseId' not in response.json() and 'startTicket' not in response.json()
    assert lease_state_snapshot()==before


def test_ticket_multiple_concurrent_operations_only_latest_registered_can_issue(client):
    with ThreadPoolExecutor(5) as pool:
        tickets=list(pool.map(lambda _:start_operation(client).json(),range(5)))
    assert len({t['version'] for t in tickets})==5
    winner=max(tickets,key=lambda t:t['version'])
    with ThreadPoolExecutor(5) as pool:
        answers=list(pool.map(lambda t:issue_ticket(client,t),tickets))
    assert sum(a.status_code==201 for a in answers)==1
    assert v3_guidance_store._vision_leases['alice'].version==winner['version']
    assert all(a.status_code in (201,410) for a in answers)


def test_ticket_expected_active_version_is_only_a_server_checked_precondition(client):
    before=lease_state_snapshot();version=v3_guidance_store._vision_start_versions['alice']
    assert start_operation(client,expectedActiveVersion=99999).status_code==409
    assert lease_state_snapshot()==before and v3_guidance_store._vision_start_versions['alice']==version


def test_ticket_capacity_rejection_does_not_forget_old_keys(client):
    from copy import copy
    original=next(op for (uid,_),op in v3_guidance_store._vision_operations.items() if uid=='alice')
    while sum(uid=='alice' for uid,_ in v3_guidance_store._vision_operations)<1024:
        op=copy(original);op.operation_id=str(uuid4());op.status='expired';op.receipt=None
        v3_guidance_store._vision_operations[('alice',op.operation_id)]=op
    before=lease_state_snapshot()
    assert start_operation(client).status_code==503 and lease_state_snapshot()==before
    assert len([uid for uid,_ in v3_guidance_store._vision_operations if uid=='alice'])==1024


@pytest.mark.parametrize("source", ["live", "replay", "android_camera"])
def test_source_registration_is_explicit_and_preview_remains_ineligible(client, source):
    payload = prepare(client, source)
    r = send(client, payload)
    assert r.status_code == 202 and r.json()["guidanceEligible"] is False
    preview = owned_preview(client, payload).json()["observations"][0]
    assert preview["sourceType"] == source and preview["guidanceEligible"] is False
    assert preview["freshnessVerified"] is False
    from app.schemas.vision_v2 import VisionSessionObservations
    VisionSessionObservations.model_validate(owned_preview(client, payload).json())


@pytest.mark.parametrize("change", ["frame-id", "missing-size", "area", "pixel-bbox", "negative-bbox",
    "bounds", "confidence", "class-name", "rotation-field", "extra-image", "source", "clock", "timestamp"])
def test_android_contract_rejects_bad_metadata_without_commit(client, change):
    from copy import deepcopy
    payload = prepare(client, "android_camera")
    before = deepcopy(vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger"))
    result = payload["detectionResult"]
    if change == "frame-id": result["frameId"] = "not-uuid"
    if change == "missing-size": result.pop("imageSize")
    if change == "area": result["imageSize"] = {"width": 4096, "height": 4097}
    if change == "pixel-bbox": result["detections"][0]["bbox"]["x"] = 64
    if change == "negative-bbox": result["detections"][0]["bbox"]["x"] = -.1
    if change == "bounds": result["detections"][0]["bbox"] = dict(x=.9,y=.1,w=.2,h=.2)
    if change == "confidence": result["detections"][0]["confidence"] = 1.1
    if change == "class-name": result["detections"][0]["className"] = "버스 문"
    if change == "rotation-field": result["rotation"] = 90
    if change == "extra-image": payload["image"] = "image-upload-not-supported"
    if change == "source": result["source"] = "webcam"
    if change == "clock": payload["captureClock"] = "sensor"
    if change == "timestamp": result["capturedAt"] = "2000-01-01T00:00:00Z"
    assert send(client, payload).status_code == 422
    assert vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger") == before
    assert owned_preview(client, payload).json()["observations"] == []


@pytest.mark.parametrize("source", ["live", "android_camera"])
@pytest.mark.parametrize("age,status", [(5,409), (6,409), (-1.01,409), (-.5,202), (0,202)])
def test_android_uses_existing_live_freshness_bounds(client, clock, source, age, status):
    payload = frame(prepare(client, source), 0, clock, age=age)
    before = deepcopy(vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger"))
    assert send(client, payload).status_code == status
    if status != 202:
        assert vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger") == before
        assert owned_preview(client,payload).json()["observations"] == []


def test_android_frame_uuid_reuse_fenced_atomically_even_nonconsecutive(client, clock):
    from copy import deepcopy
    original = frame(prepare(client, "android_camera"), 0, clock)
    first = send(client, original)
    assert first.status_code == 202
    before_ttl = owned_preview(client, original).json()["observations"][0]["validForSeconds"]
    clock.advance(.1)
    assert send(client, original).json() == first.json()
    assert owned_preview(client, original).json()["observations"][0]["validForSeconds"] < before_ttl
    second = frame(original, 1, clock)
    assert send(client, second).status_code == 202
    third = frame(original, 2, clock)
    third["detectionResult"]["frameId"] = original["detectionResult"]["frameId"].upper()
    before = deepcopy(vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger"))
    assert send(client, third).status_code == 409
    assert vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger") == before
    assert owned_preview(client, original).json()["observations"][0]["visionEventId"] == second["visionEventId"]


@pytest.mark.parametrize("mode", ["unregistered", "other-uid", "source-forgery", "reset", "revoke", "epoch", "logout", "relogin", "closed"])
def test_android_binding_security_denial_has_no_new_observation(client, mode):
    from copy import deepcopy
    payload = prepare(client, "android_camera")
    assert send(client, payload).status_code == 202
    stale = dict(payload, visionEventId=str(uuid4()), frameIndex=1)
    stale["detectionResult"] = dict(payload["detectionResult"], frameId=str(uuid4()))
    if mode == "unregistered":
        stale["producerId"] = "producer-b"
    elif mode == "other-uid":
        r=client.post("/guidance/session",headers=headers("bob"),json={});stale["sessionId"]=r.json()["sessionId"]
    elif mode == "source-forgery":
        stale["sourceType"]="live";stale["detectionResult"]["source"]="webcam"
    elif mode == "reset":
        assert client.post("/guidance/reset",headers=headers("alice"),json={"sessionId":payload["sessionId"],"event":"RESET"}).status_code==200
    elif mode == "revoke":
        assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}",headers=headers()).status_code==204
    elif mode == "epoch":
        assert client.post("/ai-vision/v2/bindings",headers=headers(),json={"cameraId":"camera-a","sessionId":payload["sessionId"]}).status_code==201
    elif mode == "logout":
        assert client.delete("/guidance/vision-lease",headers=headers("alice")).status_code==204
    elif mode == "relogin":
        fresh=issue_for(client);assert fresh.status_code==201
        LEASES["alice"]=fresh.json()["leaseId"]
    elif mode == "closed":
        marker=security.current_principal.set(security.Principal("alice","passenger",auth_time=1000,vision_lease=LEASES["alice"]))
        try:v3_guidance_store.close_vision(payload["sessionId"])
        finally:security.current_principal.reset(marker)
    before=deepcopy(vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger"))
    assert send(client,stale,"producer-b" if mode=="unregistered" else "producer").status_code==403
    assert vision_v2.vision_binding_service.ledger._injected_storage._memory_db.get("visionProducerLedger")==before
    if mode in {"reset","revoke","epoch"}:
        assert owned_preview(client,payload).json()["observations"]==[]
    elif mode in {"logout","relogin","closed"}:
        assert owned_preview(client,payload,expected=403).status_code==403
    assert all(not session.safety_items for session in v3_guidance_store._sessions.values())


@pytest.mark.parametrize("operation", ["revoke", "replace", "register", "reset", "logout", "close"])
def test_binding_revision_proof_lifecycle_snapshot(client, operation):
    payload=prepare(client,"android_camera");assert send(client,payload).status_code==202
    before=owned_preview(client,payload).json();binding=before['bindings'][0]
    assert before['viewRevision'] >= binding['bindingRevision'] > 0
    assert before['observations'][0]['bindingRevision']==binding['bindingRevision']
    assert before['observations'][0]['cameraEpoch']==binding['cameraEpoch']
    sid=payload['sessionId'];path=f'/ai-vision/v2/sessions/{sid}/observations'
    proof=client.get(path+'?proofOnly=true',headers=headers('alice')).json()
    assert proof['bindings']==before['bindings'] and proof['viewRevision']==before['viewRevision'] and proof['observations']==[]
    if operation=='revoke':assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}",headers=headers()).status_code==204
    elif operation=='replace':assert client.post('/ai-vision/v2/bindings',headers=headers(),json={'cameraId':'camera-a','sessionId':sid}).status_code==201
    elif operation=='register':assert client.put('/ai-vision/v2/cameras/camera-a',headers=headers(),json={'producerId':'producer','sourceType':'android_camera'}).status_code==200
    elif operation=='reset':assert client.post('/guidance/reset',headers=headers('alice'),json={'sessionId':sid,'event':'RESET'}).status_code==200
    elif operation=='logout':assert client.delete('/guidance/vision-lease',headers=headers('alice')).status_code==204
    else:
        marker=security.current_principal.set(security.Principal('alice','passenger',auth_time=1000,vision_lease=LEASES['alice']))
        try:v3_guidance_store.close_vision(sid)
        finally:security.current_principal.reset(marker)
    response=client.get(path+'?proofOnly=true',headers=headers('alice'))
    if operation in {'logout','close'}:assert response.status_code==403
    else:
        after=response.json();assert after['observations']==[]
        if operation=='reset':assert after['generation']!=before['generation'] and after['bindings']==[]
        else:assert after['viewRevision']>before['viewRevision']
    assert send(client,dict(payload,visionEventId=str(uuid4()),frameIndex=1)).status_code==403


def test_binding_revision_aba_tombstones_and_collision_failure(client,monkeypatch):
    payload=prepare(client,'android_camera');service=vision_v2.vision_binding_service
    first=owned_preview(client,payload).json();one=first['bindings'][0];sid=payload['sessionId']
    assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{one['bindingId']}",headers=headers()).status_code==204
    second=client.post('/ai-vision/v2/bindings',headers=headers(),json={'cameraId':'camera-a','sessionId':sid}).json()
    assert second['bindingRevision']>one['bindingRevision'] and second['cameraEpoch']!=one['cameraEpoch']
    # Force UUID allocation toward epoch A. No ID or epoch resurrection occurs.
    from uuid import UUID
    monkeypatch.setattr(bindings,'uuid4',lambda:UUID(one['cameraEpoch']))
    before=owned_preview(client,payload).json()
    assert client.post('/ai-vision/v2/bindings',headers=headers(),json={'cameraId':'camera-a','sessionId':sid}).status_code==503
    after=owned_preview(client,payload).json()
    assert after['bindings']==before['bindings'] and after['viewRevision']==before['viewRevision']
    assert client.delete(f"/ai-vision/v2/cameras/camera-a/bindings/{one['bindingId']}",headers=headers()).status_code==403
    assert owned_preview(client,payload).json()['bindings'][0]['bindingId']==second['bindingId']


@pytest.mark.parametrize('field,value',[('bindingRevision',1),('revision',0),('cameraEpoch',str(uuid4())),('bindingId',str(uuid4()))])
def test_client_cannot_choose_binding_revision_or_identity(client,field,value):
    payload=prepare(client,'android_camera');before=owned_preview(client,payload).json()
    assert client.post('/ai-vision/v2/bindings',headers=headers(),json={'cameraId':'camera-a','sessionId':payload['sessionId'],field:value}).status_code==422
    after=owned_preview(client,payload).json();assert after['bindings']==before['bindings'] and after['viewRevision']==before['viewRevision']


def test_revision_cross_uid_and_query_input_are_not_authority(client):
    payload=prepare(client,'android_camera');path=f"/ai-vision/v2/sessions/{payload['sessionId']}/observations"
    assert client.get(path+'?proofOnly=true',headers=headers('bob')).status_code==403
    assert client.get(path+'?viewRevision=1',headers=headers('alice')).status_code==422
    assert client.get(path+'?proofOnly=invalid',headers=headers('alice')).status_code==422


def test_revision_read_and_revoke_linearize_under_existing_lock(client,monkeypatch):
    import threading
    payload=prepare(client,'android_camera');assert send(client,payload).status_code==202
    entered,release=threading.Event(),threading.Event();service=vision_v2.vision_binding_service
    old=service._now;armed=[True]
    def held():
        if armed[0]:
            armed[0]=False;entered.set();assert release.wait(5)
        return old()
    monkeypatch.setattr(service,'_now',held)
    with ThreadPoolExecutor(2) as pool:
        read=pool.submit(owned_preview,client,payload);assert entered.wait(5)
        revoke=pool.submit(client.delete,f"/ai-vision/v2/cameras/camera-a/bindings/{payload['bindingId']}",headers=headers())
        release.set();first=read.result();assert first.status_code==200
        assert revoke.result().status_code==204
    final=owned_preview(client,payload).json();assert final['bindings']==[] and final['observations']==[]
    assert final['viewRevision']>first.json()['viewRevision']


@pytest.mark.parametrize("source", ["live", "android_camera"])
def test_functional_preview_projects_validated_detection_details_and_clears_on_expiry(client, monkeypatch, source):
    payload = prepare(client, source)
    result = payload["detectionResult"]
    result["frameId"] = str(uuid4())
    result["imageSize"] = {"width": 640, "height": 480}
    result["detections"] = [{"classId":"bus", "className":"버스", "confidence":.83,
                             "bbox":{"x":.1,"y":.2,"w":.3,"h":.4}}]
    assert send(client, payload).status_code == 202
    preview = owned_preview(client, payload).json()["observations"][0]
    assert preview["frameId"] == result["frameId"]
    assert preview["imageSize"] == result["imageSize"]
    assert preview["detections"] == result["detections"]
    assert preview["guidanceEligible"] is False
    service = vision_v2.vision_binding_service
    observation = service._observations[payload["cameraId"]]
    monkeypatch.setattr(service, "_mono", lambda: observation.received_mono + 4)
    monkeypatch.setattr(service, "_now", lambda: observation.received_at + timedelta(seconds=4))
    expired = owned_preview(client, payload).json()["observations"][0]
    assert expired["detections"] == [] and expired["observedClasses"] == []


# Normal passenger app flow: no administrator or producer credential on phone.
def phone_payload(binding, index=0):
    fixture = json.loads((ROOT / "ai_vision/pipelines/fixtures/mock_detection_results.json").read_text(encoding="utf-8"))["results"][0]
    fixture.update(source="android_camera", frameId=str(uuid4()),
                   capturedAt=datetime.now(timezone.utc).isoformat(), imageSize={"width": 640, "height": 480})
    payload = {k: binding[k] for k in ("bindingId", "cameraId", "producerId", "sessionId", "cameraEpoch", "sourceType")}
    return dict(payload, envelopeVersion="2.0.0", visionEventId=fixture["frameId"],
                capturedAt=fixture["capturedAt"], captureClock="host_read",
                frameIndex=index, detectionResult=fixture)


def test_passenger_phone_start_send_read_stop_restart_without_admin(client, monkeypatch):
    from app.services.safety_event_service import SafetyEventService
    monkeypatch.setattr(SafetyEventService, "create", lambda *a: pytest.fail("preview must not create safety events"))
    # Existing navigation session starts without a Vision header.
    session = client.post("/guidance/session", headers={"Authorization": "Bearer alice"}, json={}).json()
    sid = session["sessionId"]
    path = f"/ai-vision/v2/sessions/{sid}/phone-camera"
    assert client.post(path, headers={"Authorization": "Bearer alice"}).status_code == 403
    started = client.post(path, headers=headers("alice"))
    assert started.status_code == 201, started.text
    binding = started.json()
    assert binding["producerId"] == "alice"
    assert client.post(path, headers=headers("alice")).json() == binding
    payload = phone_payload(binding)
    accepted = client.post(path + "/events", headers=headers("alice"), json=payload)
    assert accepted.status_code == 202, accepted.text
    assert accepted.json()["guidanceEligible"] is False
    preview = client.get(f"/ai-vision/v2/sessions/{sid}/observations", headers=headers("alice")).json()
    assert preview["observations"][0]["frameId"] == payload["detectionResult"]["frameId"]
    # The separate external-producer API remains closed to passenger credentials.
    assert send(client, payload, "alice").status_code == 403
    assert client.post(path, headers=headers("alice")).json()["nextFrameIndex"] == 1
    assert client.delete(path + "/" + binding["bindingId"], headers=headers("alice")).status_code == 204
    assert client.get(f"/ai-vision/v2/sessions/{sid}/observations", headers=headers("alice")).json()["observations"] == []
    assert client.post(path + "/events", headers=headers("alice"), json=payload).status_code == 403
    fresh = client.post(path, headers=headers("alice")).json()
    assert fresh["cameraEpoch"] != binding["cameraEpoch"]
    assert client.post(path + "/events", headers=headers("alice"), json=phone_payload(fresh)).status_code == 202


def test_passenger_phone_cannot_bind_other_user_or_survive_reset(client):
    sid = client.post("/guidance/session", headers=headers("alice"), json={}).json()["sessionId"]
    path = f"/ai-vision/v2/sessions/{sid}/phone-camera"
    assert client.post(path, headers=headers("bob")).status_code == 403
    assert client.post(path, headers=headers("admin")).status_code == 403
    binding = client.post(path, headers=headers("alice")).json()
    payload = phone_payload(binding)
    assert client.post(path + "/events", headers=headers("bob"), json=payload).status_code == 403
    assert client.get(f"/ai-vision/v2/sessions/{sid}/observations", headers=headers("bob")).status_code == 403
    assert client.post("/guidance/reset", headers=headers("alice"), json={"sessionId": sid, "event": "RESET"}).status_code == 200
    assert client.post(path + "/events", headers=headers("alice"), json=payload).status_code == 403
    assert client.get(f"/ai-vision/v2/sessions/{sid}/observations", headers=headers("alice")).json()["observations"] == []
