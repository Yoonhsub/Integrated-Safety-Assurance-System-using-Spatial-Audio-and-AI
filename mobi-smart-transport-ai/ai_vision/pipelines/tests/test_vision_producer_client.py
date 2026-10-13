"""Deterministic transport tests; no Firebase, weights or camera access."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
from uuid import uuid4

import httpx
import pytest

from ai_vision.pipelines.vision_producer_client import (
    EmulatorProducerAuth, ProducerError, RetryPolicy, VisionEvent, VisionProducerClient,
)


class Clock:
    value = 0.0
    def __call__(self): return self.value
    def sleep(self, seconds): self.value += seconds
    def utc(self): return datetime(2026, 10, 13, tzinfo=timezone.utc) + timedelta(seconds=self.value)


class Auth:
    uid = "producer"
    refreshes = 0
    def token(self, *, force_refresh=False):
        if force_refresh: self.refreshes += 1
        return "renewed" if self.refreshes else "first"


def binding():
    return dict(producerId="producer", cameraId="camera", sessionId="session",
                bindingId=str(uuid4()), cameraEpoch=str(uuid4()), sourceType="live")


def event(b, clock, index=0):
    timestamp = clock.utc().isoformat()
    detection = dict(schemaVersion="1.0.0", source="webcam", status="ok", frameId=str(uuid4()),
                     capturedAt=timestamp, modelInfo=dict(provider="mock", name="fixture"), detections=[])
    return VisionEvent.create(b, detection, frame_index=index, captured_at=timestamp)


def receipt(request):
    data = json.loads(request.content)
    return dict(visionEventId=data["visionEventId"], bindingId=data["bindingId"],
                receivedAt="2026-10-13T00:00:00Z", accepted=True, stored=False,
                guidanceEligible=False, freshnessVerified=False, mode="local-validation-only")


def client(handler, *, policy=None):
    clock, auth, b = Clock(), Auth(), binding()
    c = VisionProducerClient("http://127.0.0.1:8011", auth, policy=policy,
        transport=httpx.MockTransport(handler), clock=clock, utc_clock=clock.utc, sleep=clock.sleep)
    c.attach_binding(b)
    return c, b, clock, auth


def test_immutable_snapshot_and_server_schema():
    clock, b = Clock(), binding()
    e = event(b, clock)
    copied = e.payload()
    copied["detectionResult"]["status"] = "error"
    assert e.payload()["detectionResult"]["status"] == "ok"
    assert event(b, clock).payload()["visionEventId"] != e.payload()["visionEventId"]
    with pytest.raises(Exception): e.body = b"changed"
    from app.schemas.vision_v2 import VisionEnvelope
    VisionEnvelope.model_validate(e.payload())


@pytest.mark.parametrize("status", [403, 409, 422, 400, 500, 302])
def test_terminal_http_errors(status):
    calls = []
    c, b, clock, _ = client(lambda r: (calls.append(r), httpx.Response(status))[1])
    with pytest.raises(ProducerError) as error: c.send(event(b, clock))
    assert error.value.status == status and len(calls) == 1


@pytest.mark.parametrize("first", ["timeout", 503, 401])
def test_retry_same_bytes_and_only_header_changes(first):
    requests = []
    def handler(request):
        requests.append(request)
        if len(requests) == 1:
            if first == "timeout": raise httpx.ReadTimeout("secret-hidden", request=request)
            return httpx.Response(first)
        return httpx.Response(202, json=receipt(request))
    c, b, clock, auth = client(handler)
    e = event(b, clock)
    assert c.send(e)["accepted"] is True
    assert requests[0].content == requests[1].content == e.body
    assert auth.refreshes == (1 if first == 401 else 0)
    assert requests[1].headers["authorization"] == ("Bearer renewed" if first == 401 else "Bearer first")


def test_401_refresh_only_once():
    calls = []
    c, b, clock, auth = client(lambda r: (calls.append(r), httpx.Response(401))[1])
    with pytest.raises(ProducerError): c.send(event(b, clock))
    assert len(calls) == 2 and auth.refreshes == 1


def test_uncertain_blocks_next_frame_and_reattach_cannot_clear():
    calls = []
    c, b, clock, _ = client(lambda r: (calls.append(r), httpx.Response(503))[1])
    e = event(b, clock)
    with pytest.raises(ProducerError) as failure: c.send(e)
    assert failure.value.uncertain and len(calls) == 3
    assert clock.value == pytest.approx(.3)
    c.attach_binding(b)
    with pytest.raises(ProducerError, match="PREVIOUS_EVENT_UNCERTAIN"): c.send(event(b, clock, 1))
    c.attach_binding(dict(b, bindingId=str(uuid4()), cameraEpoch=str(uuid4())))
    with pytest.raises(ProducerError, match="BINDING_INVALIDATED"): c.send(e)


def test_expired_unsent_vs_expired_uncertain():
    c, b, clock, _ = client(lambda r: httpx.Response(503),
        policy=RetryPolicy(initial_delay=1, event_max_age=.5))
    e = event(b, clock)
    with pytest.raises(ProducerError) as failure: c.send(e)
    assert failure.value.uncertain
    clock.sleep(1)
    with pytest.raises(ProducerError) as expired: c.send(e)
    assert expired.value.uncertain
    new = event(b, clock, 1)
    with pytest.raises(ProducerError, match="PREVIOUS_EVENT_UNCERTAIN"): c.send(new)
    c2, b2, t2, _ = client(lambda r: pytest.fail("No request expected"))
    e2 = event(b2, t2)
    t2.sleep(10)
    with pytest.raises(ProducerError) as unsent: c2.send(e2)
    assert not unsent.value.uncertain


def test_concurrent_duplicate_serialized_and_reverse_new_frame_rejected():
    calls = []
    def handler(r):
        calls.append(r)
        return httpx.Response(202, json=receipt(r))
    c, b, clock, _ = client(handler)
    e = event(b, clock, 10)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(c.send, [e]*4))
    assert results.count(results[0]) == 4 and len(calls) == 4
    c.send(event(b, clock, 11))
    with pytest.raises(ProducerError, match="FRAME_ORDER_REJECTED"): c.send(event(b, clock, 9))
    assert c.send(e) == results[0]


def test_invalid_success_receipt_keeps_uncertainty():
    c, b, clock, _ = client(lambda r: httpx.Response(202, json=dict(receipt(r), stored=True)))
    with pytest.raises(ProducerError, match="INVALID_RECEIPT") as failure: c.send(event(b, clock))
    assert failure.value.uncertain


@pytest.mark.parametrize("url", ["https://firebase.example", "http://localhost:9099",
                                     "http://127.0.0.1:9099/path", "http://user:secret@127.0.0.1:9099"])
def test_local_only_boundary(url):
    with pytest.raises(ValueError): EmulatorProducerAuth(project_id="demo-mobi-local", emulator_url=url)
    with pytest.raises(ValueError): EmulatorProducerAuth(project_id="production")


def test_auth_login_proactive_refresh_failure_and_secret_redaction():
    clock, calls = Clock(), []
    def handle(r):
        calls.append(r)
        if len(calls) == 1:
            return httpx.Response(200, json=dict(idToken="id-secret", refreshToken="refresh-secret",
                localId="producer", expiresIn="3600"))
        if len(calls) == 2:
            return httpx.Response(200, json=dict(id_token="new-secret", refresh_token="refresh-secret",
                user_id="producer", expires_in="3600"))
        return httpx.Response(503, text="secret-body")
    auth = EmulatorProducerAuth(project_id="demo-mobi-local", clock=clock, transport=httpx.MockTransport(handle))
    auth.login("a@example.test", "password-secret")
    assert auth.uid == "producer" and auth.token() == "id-secret"
    clock.sleep(3541)
    assert auth.token() == "new-secret"
    assert calls[1].url.path == "/securetoken.googleapis.com/v1/token"
    with pytest.raises(ProducerError) as error: auth.token(force_refresh=True)
    assert "secret" not in str(error.value)
    auth.close()
    with pytest.raises(ProducerError): auth.token()


def test_auth_uid_change_fails_closed():
    responses = [dict(idToken="one", refreshToken="refresh", localId="producer", expiresIn="3600"),
                 dict(id_token="two", refresh_token="refresh", user_id="other", expires_in="3600")]
    auth = EmulatorProducerAuth(project_id="demo-mobi-local", transport=httpx.MockTransport(
        lambda r: httpx.Response(200, json=responses.pop(0))))
    auth.login("x", "y")
    with pytest.raises(ProducerError, match="AUTH_INVALID_RESPONSE"): auth.token(force_refresh=True)


def test_401_without_retry_budget_is_known_rejection():
    c, b, clock, _ = client(lambda r: httpx.Response(401), policy=RetryPolicy(max_attempts=1))
    with pytest.raises(ProducerError) as error: c.send(event(b, clock))
    assert error.value.status == 401 and not error.value.uncertain


def test_backoff_is_capped_and_max_attempts_respected():
    waits, calls = [], []
    c, b, clock, _ = client(lambda r: (calls.append(r), httpx.Response(503))[1],
        policy=RetryPolicy(max_attempts=5, initial_delay=.1, max_delay=.15))
    def wait(value): waits.append(value); clock.sleep(value)
    c._sleep = wait
    with pytest.raises(ProducerError): c.send(event(b, clock))
    assert waits == [.1, .15, .15, .15] and len(calls) == 5


def test_auth_service_failure_is_closed_without_backend_request():
    c, b, clock, auth = client(lambda r: pytest.fail("No authenticated request allowed"))
    def failed(**kwargs): raise ProducerError("AUTH_UNAVAILABLE")
    auth.token = failed
    with pytest.raises(ProducerError) as error: c.send(event(b, clock))
    assert error.value.code == "AUTH_UNAVAILABLE" and not error.value.uncertain


def test_new_binding_cannot_reuse_epoch():
    c, b, _, _ = client(lambda r: pytest.fail("No HTTP expected"))
    with pytest.raises(ProducerError, match="NEW_BINDING_REQUIRES_NEW_EPOCH"):
        c.attach_binding(dict(b, bindingId=str(uuid4())))


def test_two_new_frames_have_one_in_flight_and_binding_change_waits():
    import threading
    started, release = threading.Event(), threading.Event()
    calls = []
    def handler(r):
        calls.append(json.loads(r.content)["frameIndex"])
        if len(calls) == 1:
            started.set()
            assert release.wait(2)
        return httpx.Response(202, json=receipt(r))
    c, b, clock, _ = client(handler)
    first, second = event(b, clock, 1), event(b, clock, 2)
    with ThreadPoolExecutor(max_workers=2) as pool:
        a = pool.submit(c.send, first)
        assert started.wait(2)
        z = pool.submit(c.send, second)
        assert calls == [1]
        release.set()
        assert a.result()["accepted"] and z.result()["accepted"]
    assert calls == [1, 2]
    c.attach_binding(dict(b, bindingId=str(uuid4()), cameraEpoch=str(uuid4())))
    with pytest.raises(ProducerError, match="BINDING_INVALIDATED"): c.send(second)


@pytest.mark.parametrize("field,value", [("frameIndex", True), ("frameIndex", -1),
                                          ("capturedAt", "no-time"), ("captureClock", "trusted")])
def test_malformed_envelope_rejected_before_send(field, value):
    raw = event(binding(), Clock()).payload()
    raw[field] = value
    with pytest.raises(Exception): VisionEvent(json.dumps(raw).encode())


@pytest.mark.parametrize("status", [400, 503])
def test_login_failure_sanitizes_server_body(status):
    auth = EmulatorProducerAuth(project_id="demo-mobi-local", transport=httpx.MockTransport(
        lambda r: httpx.Response(status, text="password-secret")))
    with pytest.raises(ProducerError) as failure: auth.login("x", "password-secret")
    assert "secret" not in str(failure.value)
    with pytest.raises(ProducerError, match="AUTH_LOGIN_REQUIRED"): auth.token()


@pytest.mark.parametrize("detail,code", [("VISION_EVENT_ID_CONFLICT", "EVENT_ID_CONFLICT"),
    ("Duplicate or out-of-order frameIndex", "FRAME_ORDER_REJECTED"),
    ("Frame is too old", "OLD_FRAME_REJECTED"), ("password-secret", "HTTP_REJECTED")])
def test_409_reason_whitelist(detail, code):
    c, b, clock, _ = client(lambda r: httpx.Response(409, json={"detail": detail}))
    with pytest.raises(ProducerError) as error: c.send(event(b, clock))
    assert error.value.code == code and "secret" not in str(error.value)
