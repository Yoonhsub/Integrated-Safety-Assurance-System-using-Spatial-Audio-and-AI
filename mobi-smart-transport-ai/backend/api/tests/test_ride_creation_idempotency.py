from concurrent.futures import ThreadPoolExecutor
from threading import Lock
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.schemas.ride_request import RideRequestCreate, RideRequestStatus
from app.services.ride_request_service import RideRequestService
from test_ride_request_concurrency import storage, as_user  # noqa: F401; shared memory/opt-in RTDB fixture


@pytest.fixture
def creation(storage):
    client, _, ids, _ = storage
    driver = "creation-driver-" + uuid4().hex
    client.set("/drivers/" + driver, {"routeId": "MOCK-502", "busNo": "502"})
    calls = []
    lock = Lock()

    def notify(**kwargs):
        with lock:
            calls.append(kwargs)
        return SimpleNamespace(accepted=True)

    fcm = SimpleNamespace(send_ride_request_notification=notify)
    payload = RideRequestCreate(userId="race-passenger", targetDriverId=driver,
                                stopId="mock-stop-001", routeId="MOCK-502", busNo="502")
    key = uuid4().hex

    def create(body=None, request_key=None, uid="race-passenger", service=None):
        body = body or payload
        k = request_key or key
        rid, _ = RideRequestService._creation_identity(uid, k, body)
        with lock:
            if rid not in ids:
                ids.append(rid)
        with as_user("passenger", uid=uid):
            return (service or RideRequestService(client, fcm)).create(body, k)

    yield SimpleNamespace(client=client, calls=calls, fcm=fcm, payload=payload, key=key, create=create)
    client.delete("/drivers/" + driver)


def test_repeat_and_concurrent_posts_keep_one_request_and_notification(creation):
    c = creation
    with ThreadPoolExecutor(max_workers=6) as pool:
        records = list(pool.map(lambda _: c.create(), range(12)))
    repeated = c.create()
    assert {r.requestId for r in records} == {repeated.requestId}
    assert len({r.createdAt for r in records}) == 1
    assert len(c.calls) == 1
    assert repeated.status == RideRequestStatus.NOTIFIED
    assert "_creation" not in repeated.model_dump()
    with as_user("driver", driver_id=c.payload.targetDriverId):
        assert repeated.requestId in {r.requestId for r in RideRequestService(c.client).list_by_driver(c.payload.targetDriverId).requests}


def test_same_key_different_payload_conflicts(creation):
    c = creation
    first = c.create()
    with pytest.raises(HTTPException) as error:
        c.create(c.payload.model_copy(update={"stopId": "changed-stop"}))
    assert error.value.status_code == 409
    assert c.create().requestId == first.requestId
    assert len(c.calls) == 1


def test_same_key_scoped_to_authenticated_uid_and_spoof_denied(creation):
    c = creation
    first = c.create()
    second = c.create(c.payload.model_copy(update={"userId": "another-passenger"}), uid="another-passenger")
    assert first.requestId != second.requestId
    with pytest.raises(HTTPException) as error:
        c.create(uid="forged-user")
    assert error.value.status_code == 403


def test_cancelled_replay_returns_cancelled_new_key_creates_new_request(creation):
    c = creation
    first = c.create()
    with as_user("passenger"):
        RideRequestService(c.client).update_status(first.requestId, RideRequestStatus.CANCELLED)
    assert c.create().status == RideRequestStatus.CANCELLED
    assert len(c.calls) == 1
    assert c.create(request_key=uuid4().hex).requestId != first.requestId
    assert len(c.calls) == 2


@pytest.mark.parametrize("after_commit", [False, True])
def test_storage_error_retry_recovers_without_duplicates(creation, monkeypatch, after_commit):
    c = creation
    original = c.client.transaction
    failed = False

    def fail_once(path, callback):
        nonlocal failed
        if not failed:
            failed = True
            if after_commit:
                original(path, callback)
            raise HTTPException(503, "Simulated lost acknowledgement")
        return original(path, callback)

    monkeypatch.setattr(c.client, "transaction", fail_once)
    with pytest.raises(HTTPException):
        c.create()
    # A new service instance simulates process restart; no local deduplication cache.
    result = c.create(service=RideRequestService(c.client, c.fcm))
    assert c.create().requestId == result.requestId
    assert len(c.calls) == 1


def test_lost_http_response_replay_does_not_resend(creation):
    c = creation
    c.create()  # Discard a successful response, as with a client timeout.
    result = c.create(service=RideRequestService(c.client, c.fcm))
    assert result.status == RideRequestStatus.NOTIFIED
    assert len(c.calls) == 1


def test_legacy_no_key_is_explicitly_not_deduplicated(creation, storage):
    c = creation
    _, _, ids, _ = storage
    with as_user("passenger"):
        service = RideRequestService(c.client, c.fcm)
        first = service.create(c.payload)
        ids.append(first.requestId)
        second = service.create(c.payload)
        ids.append(second.requestId)
    assert first.requestId != second.requestId
    assert len(c.calls) == 2


def test_cancelled_pending_notification_is_skipped_on_recovery(creation, monkeypatch):
    c = creation
    service = RideRequestService(c.client, c.fcm)
    monkeypatch.setattr(service, "_notify_idempotent", lambda *args: None)
    first = c.create(service=service)  # Crash window after creation, before claiming notification.
    with as_user("passenger"):
        RideRequestService(c.client).update_status(first.requestId, RideRequestStatus.CANCELLED)
    assert c.create().status == RideRequestStatus.CANCELLED
    assert not c.calls
    assert c.client.get("/rideRequests/" + first.requestId)["_creation"]["notification"]["state"] == "skipped"


@pytest.mark.parametrize("outcome", ["failed", "unknown", "crash"])
def test_notification_ambiguous_outcome_never_auto_retries(creation, outcome):
    c = creation
    count = []

    class ProcessStopped(BaseException):
        pass

    def send(**kwargs):
        count.append(kwargs)
        if outcome == "crash":
            raise ProcessStopped()
        if outcome == "unknown":
            raise RuntimeError("Ambiguous transport failure")
        return SimpleNamespace(accepted=False)

    c.fcm.send_ride_request_notification = send
    if outcome == "crash":
        with pytest.raises(ProcessStopped):
            c.create()
    else:
        c.create()
    result = c.create()
    assert result.status == RideRequestStatus.WAITING
    assert len(count) == 1
    raw = c.client.get("/rideRequests/" + result.requestId)
    assert raw["_creation"]["notification"]["state"] == ("claimed" if outcome == "crash" else outcome)


def test_replay_keeps_original_assignment_even_if_registry_changes(creation):
    c = creation
    first = c.create()
    c.client.update("/drivers/" + c.payload.targetDriverId, {"routeId": "different-route"})
    assert c.create().requestId == first.requestId


@pytest.mark.parametrize("key", ["", "short", "x" * 129, "a" * 16 + "/", "한글" * 16])
def test_invalid_key_rejected_without_writes(storage, key):
    client, _, _, _ = storage
    with as_user("passenger"):
        with pytest.raises(HTTPException) as error:
            RideRequestService(client).create(RideRequestCreate(userId="race-passenger", stopId="s", routeId="r", busNo="b"), key)
    assert error.value.status_code == 400
