"""Atomic ledger tests; opt-in uses real local RTDB, with explicit fault injection."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import os
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.schemas.vision_v2 import VisionEnvelope, VisionReceipt
from app.services.firebase_client import FirebaseClient, FirebaseSettings
from app.services.vision_event_ledger import VisionEventLedger, producer_path


@pytest.fixture
def ledger(monkeypatch):
    real = os.getenv("RUN_LOCAL_VISION_LEDGER") == "1"
    if real:
        monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[3] / "scripts"))
        from local_demo import ENVIRONMENT
        from app.local_emulator import validate_local_emulators
        for key, value in ENVIRONMENT.items():
            monkeypatch.setenv(key, value)
        validate_local_emulators()
    storage = FirebaseClient(FirebaseSettings(
        project_id="demo-mobi-local" if real else None,
        database_url="https://demo-mobi-local-default-rtdb.firebaseio.com" if real else None,
        service_account_path=None, storage_bucket=None, use_mock_data=not real,
        use_emulator=real, require_real_storage=real,
    ))
    if real:
        assert storage.initialize() and not storage.using_mock
    uid = "ledger-test-" + uuid4().hex
    yield VisionEventLedger(storage), storage, uid
    storage.delete(producer_path(uid))


def request(uid):
    now = datetime.now(timezone.utc).isoformat()
    return VisionEnvelope.model_validate({
        "envelopeVersion": "2.0.0", "producerId": uid, "cameraId": "camera",
        "sessionId": "test-session", "bindingId": str(uuid4()), "cameraEpoch": str(uuid4()),
        "visionEventId": str(uuid4()), "sourceType": "live", "capturedAt": now,
        "frameIndex": 10, "detectionResult": {"schemaVersion": "1.0.0", "source": "webcam", "status": "ok",
            "capturedAt": now, "frameId": str(uuid4()), "modelInfo": {"provider": "mock", "name": "fixture"}, "detections": []}})


def candidate(uid, value):
    now = datetime.now(timezone.utc)
    return {"producerUid": uid, "visionEventId": str(value.visionEventId), "bindingId": str(value.bindingId),
            "cameraId": value.cameraId, "cameraEpoch": str(value.cameraEpoch), "sessionId": value.sessionId,
            "ownerUid": "test-owner", "sessionGeneration": "generation", "sourceType": value.sourceType,
            "firstProcessedAt": now.isoformat(), "attemptId": str(uuid4()),
            "response": VisionReceipt(visionEventId=value.visionEventId, bindingId=value.bindingId, receivedAt=now).model_dump(mode="json")}


def validate(value, previous):
    if previous is not None and value.frameIndex <= previous["frameIndex"]:
        raise HTTPException(409, "Out of order")


def test_concurrent_atomic_receipt_and_watermark(ledger):
    service, storage, uid = ledger
    value = request(uid)
    def commit(_):
        return service.commit(uid, value, candidate(uid, value), lambda p: validate(value, p))
    with ThreadPoolExecutor(4) as pool:
        records = list(pool.map(commit, range(8)))
    assert all(r == records[0] for r in records)
    raw = storage.get(producer_path(uid))
    assert len(raw["events"]) == 1
    assert raw["streams"][str(value.bindingId)]["frameIndex"] == 10


@pytest.mark.parametrize("after_commit", [False, True])
def test_store_error_then_confirmed_recovery(ledger, monkeypatch, after_commit):
    service, storage, uid = ledger
    value = request(uid)
    transaction = storage.transaction
    def fail(path, transform):
        if after_commit:
            transaction(path, transform)  # A real commit in opt-in mode.
        raise RuntimeError("Injected unconfirmed transport response")
    monkeypatch.setattr(storage, "transaction", fail)
    with pytest.raises(HTTPException) as error:
        service.commit(uid, value, candidate(uid, value), lambda p: validate(value, p))
    assert error.value.status_code == 503
    monkeypatch.setattr(storage, "transaction", transaction)
    stored = service.commit(uid, value, candidate(uid, value), lambda p: validate(value, p))
    raw = storage.get(producer_path(uid))
    assert len(raw["events"]) == 1
    assert raw["streams"][str(value.bindingId)]["frameIndex"] == 10
    assert stored == next(iter(raw["events"].values()))


def test_ledger_recreation_preserves_response_and_conflict(ledger):
    service, storage, uid = ledger
    value = request(uid)
    original = service.commit(uid, value, candidate(uid, value), lambda p: validate(value, p))
    replacement = VisionEventLedger(storage)
    assert replacement.commit(uid, value, candidate(uid, value), lambda p: validate(value, p)) == original
    changed = value.model_copy(update={"frameIndex": 11})
    with pytest.raises(HTTPException) as error:
        replacement.commit(uid, changed, candidate(uid, changed), lambda p: validate(changed, p))
    assert error.value.status_code == 409


def test_latest_watermark_not_reversed_by_old_event_retry(ledger):
    service, storage, uid = ledger
    first = request(uid)
    service.commit(uid, first, candidate(uid, first), lambda p: validate(first, p))
    second = first.model_copy(update={"visionEventId": uuid4(), "frameIndex": 11})
    service.commit(uid, second, candidate(uid, second), lambda p: validate(second, p))
    service.commit(uid, first, candidate(uid, first), lambda p: validate(first, p))
    raw = storage.get(producer_path(uid))
    assert len(raw["events"]) == 2
    assert raw["streams"][str(first.bindingId)]["frameIndex"] == 11


def test_corrupt_record_is_never_overwritten_as_new(ledger):
    service, storage, uid = ledger
    storage.set(producer_path(uid), {"version": 1, "producerUid": "other"})
    value = request(uid)
    with pytest.raises(HTTPException) as error:
        service.commit(uid, value, candidate(uid, value), lambda p: validate(value, p))
    assert error.value.status_code == 503
    assert storage.get(producer_path(uid))["producerUid"] == "other"
