"""HTTP auth boundary tests with mocked Firebase verifier, not real hardware."""
import json
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
        return {"uid": token, "exp": time.time() + 3600, "mobi_role": "admin"}

    roles = {"producer": "vision_producer", "producer-b": "vision_producer",
             "alice": "passenger", "bob": "passenger", "driver": "driver", "admin": "admin"}
    monkeypatch.setattr(security.auth, "verify_id_token", verify)
    monkeypatch.setattr(security.auth, "get_user", lambda uid, **kw: SimpleNamespace(
        disabled=False, custom_claims={"mobi_role": roles[uid], "mobi_driver_id": "fleet-a"}))
    marker = security.current_principal.set(None)
    try:
        with TestClient(app) as http:
            yield http
    finally:
        security.current_principal.reset(marker)
        app.dependency_overrides.clear()
        app.dependency_overrides.update(previous)
        v3_guidance_store.clear()


def headers(uid="admin"):
    return {"Authorization": "Bearer " + uid}


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
    fixture["source"] = "webcam" if source == "live" else "video_file"
    fixture["capturedAt"] = datetime.now(timezone.utc).isoformat()
    payload = {k: binding[k] for k in ("bindingId", "cameraId", "producerId", "sessionId", "cameraEpoch", "sourceType")}
    payload.update(envelopeVersion="2.0.0", visionEventId=str(uuid4()), capturedAt=fixture["capturedAt"],
                   frameIndex=0, detectionResult=fixture)
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
        marker = security.current_principal.set(security.Principal("alice", "passenger"))
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
        marker = security.current_principal.set(security.Principal("alice", "passenger"))
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
        marker = security.current_principal.set(security.Principal("alice", "passenger"))
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
    token=current_principal.set(Principal('alice','passenger'))
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
