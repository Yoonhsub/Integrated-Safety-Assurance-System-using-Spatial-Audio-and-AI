"""Ordinary tests use memory; opt-in RTDB tests use only the local demo emulator."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
import os
from threading import Event
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.schemas.ride_request import RideRequestCreate, RideRequestStatus as Status
from app.security import Principal, current_principal
from app.services.firebase_client import FirebaseClient, FirebaseSettings
from app.services.ride_request_service import RideRequestService


@contextmanager
def as_user(role, uid="race-passenger", driver_id=None):
    token = current_principal.set(Principal(uid, role, driver_id))
    try:
        yield
    finally:
        current_principal.reset(token)


@pytest.fixture
def storage(monkeypatch):
    real = os.getenv("RUN_LOCAL_RIDE_CONCURRENCY") == "1"
    if real:
        # Explicit loopback-only configuration, never use a real project's credentials.
        from app.local_emulator import validate_local_emulators
        from pathlib import Path
        monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[3] / "scripts"))
        from local_demo import ENVIRONMENT
        for key, value in ENVIRONMENT.items():
            monkeypatch.setenv(key, value)
        validate_local_emulators()
    client = FirebaseClient(FirebaseSettings(
        project_id="demo-mobi-local" if real else None,
        database_url="https://demo-mobi-local-default-rtdb.firebaseio.com" if real else None,
        service_account_path=None, storage_bucket=None, use_mock_data=not real,
        require_real_storage=real, use_emulator=real,
    ))
    if real:
        assert client.initialize(), "Local RTDB initialization failed"
        assert not client.using_mock
    ids = []

    def seed(status=Status.WAITING):
        rid = "race-" + uuid4().hex
        ids.append(rid)
        client.set(f"/rideRequests/{rid}", {
            "userId": "race-passenger", "targetDriverId": "race-driver",
            "stopId": "mock-stop-001", "routeId": "MOCK-502", "busNo": "502",
            "status": status.value, "createdAt": "2026-01-01T00:00:00+00:00",
        })
        return rid

    yield client, seed, ids, real
    for rid in ids:
        client.delete(f"/rideRequests/{rid}")


def update(service, rid, status, role="driver", driver_id="race-driver"):
    with as_user(role, driver_id=driver_id):
        return service.update_status(rid, status)


@pytest.mark.parametrize("old", list(Status))
@pytest.mark.parametrize("new", list(Status))
def test_transition_matrix(storage, old, new):
    client, seed, _, _ = storage
    rid = seed(old)
    service = RideRequestService(client)
    allowed = {
        Status.WAITING: {Status.ACCEPTED, Status.CANCELLED},
        Status.NOTIFIED: {Status.ACCEPTED, Status.CANCELLED},
        Status.ACCEPTED: {Status.ARRIVED, Status.COMPLETED, Status.CANCELLED},
        Status.ARRIVED: {Status.COMPLETED, Status.CANCELLED},
        Status.COMPLETED: set(), Status.CANCELLED: set(),
    }
    if new == old or new in allowed[old]:
        assert update(service, rid, new).status == new
    else:
        with pytest.raises(HTTPException) as error:
            update(service, rid, new)
        assert error.value.status_code == 409
        assert client.get(f"/rideRequests/{rid}")["status"] == old.value


def test_duplicate_accept_preserves_timestamp(storage):
    client, seed, _, _ = storage
    rid = seed()
    service = RideRequestService(client)
    first = update(service, rid, Status.ACCEPTED)
    with ThreadPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(lambda _: update(service, rid, Status.ACCEPTED), range(8)))
    assert all(row.updatedAt == first.updatedAt for row in rows)


@pytest.mark.parametrize("final", [Status.CANCELLED, Status.ACCEPTED, Status.COMPLETED])
def test_late_notification_does_not_reverse_state(storage, monkeypatch, final):
    client, _, ids, _ = storage
    rid = "race-" + uuid4().hex
    ids.append(rid)
    calls = []

    def send(**kwargs):
        calls.append(kwargs)
        other = RideRequestService(client)
        if final == Status.COMPLETED:
            update(other, rid, Status.ACCEPTED)
        update(other, rid, final, role="passenger" if final == Status.CANCELLED else "driver")
        return SimpleNamespace(accepted=True)

    service = RideRequestService(client, SimpleNamespace(send_ride_request_notification=send))
    monkeypatch.setattr(service, "_new_request_id", lambda: rid)
    with as_user("admin"):
        result = service.create(RideRequestCreate(userId="race-passenger", targetDriverId="race-driver",
                              stopId="s", routeId="MOCK-502", busNo="502"))
    assert result.status == final
    assert len(calls) == 1


@pytest.mark.parametrize("race", ["cancel", "reassign", "delete"])
def test_stale_read_rechecked_by_real_transaction(storage, monkeypatch, race):
    client, seed, _, real = storage
    if not real:
        pytest.skip("Requires opt-in real RTDB ETag conflict/retry")
    rid = seed()
    path = f"/rideRequests/{rid}"
    read, release = Event(), Event()
    paused = False

    def pause(raw):
        nonlocal paused
        if not paused:
            paused = True
            read.set()
            assert release.wait(15), "Concurrent actor did not finish"
        return raw

    # Before fix pause get(); after fix pause the first SDK callback with its ETag.
    if hasattr(client, "transaction"):
        original = client.transaction
        monkeypatch.setattr(client, "transaction", lambda p, fn: original(p, lambda raw: fn(pause(raw))))
    else:
        original = client.get
        monkeypatch.setattr(client, "get", lambda p: pause(original(p)))

    service = RideRequestService(client)
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(update, service, rid, Status.ACCEPTED)
        try:
            assert read.wait(15)
            # Independent SDK reference represents another process, no Python lock shared.
            ref = client._real_reference(path)
            if race == "cancel":
                ref.update({"status": "CANCELLED"})
            elif race == "reassign":
                ref.update({"targetDriverId": "other-driver"})
            else:
                ref.delete()
        finally:
            release.set()
        with pytest.raises(HTTPException) as error:
            future.result(timeout=15)
    assert error.value.status_code == {"cancel": 409, "reassign": 403, "delete": 404}[race]
    raw = client._real_reference(path).get()
    if race == "cancel":
        assert raw["status"] == "CANCELLED"
    elif race == "reassign":
        assert raw["status"] == "WAITING"
    else:
        assert raw is None


def test_simultaneous_accept_cancel_and_foreign_driver(storage):
    client, seed, _, _ = storage
    rid = seed()

    def attempt(status, role, driver):
        try:
            return update(RideRequestService(client), rid, status, role, driver).status.value
        except HTTPException as error:
            return error.status_code

    with ThreadPoolExecutor(max_workers=3) as pool:
        jobs = [pool.submit(attempt, Status.ACCEPTED, "driver", "race-driver"),
                pool.submit(attempt, Status.CANCELLED, "passenger", None),
                pool.submit(attempt, Status.ACCEPTED, "driver", "other-driver")]
        results = [job.result(timeout=15) for job in jobs]
    assert results[0] in {"ACCEPTED", 409}
    assert results[1:] == ["CANCELLED", 403]
    assert client.get(f"/rideRequests/{rid}")["status"] == "CANCELLED"


def test_clock_regression_does_not_decrease_updated_at(storage, monkeypatch):
    client, seed, _, _ = storage
    rid = seed()
    service = RideRequestService(client)
    first = update(service, rid, Status.ACCEPTED)
    monkeypatch.setattr(service, "_utc_now", lambda: datetime(2000, 1, 1, tzinfo=timezone.utc))
    second = update(service, rid, Status.ARRIVED)
    assert second.updatedAt > first.updatedAt


def test_passenger_cannot_accept_or_cancel_another_users_request(storage):
    client, seed, _, _ = storage
    rid = seed()
    service = RideRequestService(client)
    with pytest.raises(HTTPException) as error:
        update(service, rid, Status.ACCEPTED, role="passenger")
    assert error.value.status_code == 403
    with as_user("passenger", uid="other-passenger"):
        with pytest.raises(HTTPException) as error:
            service.update_status(rid, Status.CANCELLED)
        assert error.value.status_code == 403
    assert client.get(f"/rideRequests/{rid}")["status"] == "WAITING"


@pytest.mark.parametrize("failure, expected", [("conflict", 409), ("unavailable", 503)])
def test_transaction_failure_never_falls_back_to_unconditional_write(monkeypatch, failure, expected):
    from firebase_admin import db, exceptions
    client = FirebaseClient(FirebaseSettings(None, None, None, None, True))
    monkeypatch.setattr(client, "_use_memory", lambda: False)

    def fail(_):
        if failure == "conflict":
            raise db.TransactionAbortedError("test retry exhaustion")
        raise exceptions.UnavailableError("test outage")

    monkeypatch.setattr(client, "_real_reference", lambda _: SimpleNamespace(transaction=fail))
    with pytest.raises(HTTPException) as error:
        client.transaction("/rideRequests/test", lambda raw: raw)
    assert error.value.status_code == expected
    assert client._memory_db.get("/rideRequests/test") is None


def test_memory_transaction_abort_keeps_original_record():
    from app.services.firebase_client import InMemoryRealtimeDatabase
    store = InMemoryRealtimeDatabase()
    store.set("/request", {"status": "CANCELLED"})

    def reject(raw):
        raw["status"] = "ACCEPTED"
        raise HTTPException(409, "reject")

    with pytest.raises(HTTPException):
        store.transaction("/request", reject)
    assert store.get("/request") == {"status": "CANCELLED"}
