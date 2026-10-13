"""Atomic receipts and watermark under one authenticated producer RTDB node."""
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json

from fastapi import HTTPException

from app.schemas.vision_v2 import VisionEnvelope, VisionReceipt
from app.security import auth_error
from app.services.firebase_client import FirebaseClient, get_firebase_client


def producer_path(uid: str) -> str:
    return "/visionProducerLedger/" + hashlib.sha256(uid.encode("utf-8")).hexdigest()


def event_key(event_id: str) -> str:
    return hashlib.sha256(event_id.encode("ascii")).hexdigest()


def fingerprint(request: VisionEnvelope) -> str:
    payload = request.model_dump(mode="json")
    # Normalize equivalent timezone representations; array ordering is preserved.
    payload["capturedAt"] = request.capturedAt.astimezone(timezone.utc).isoformat()
    if "capturedAt" in payload["detectionResult"]:
        value = payload["detectionResult"]["capturedAt"]
        payload["detectionResult"]["capturedAt"] = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat()

    def normalize(value):
        if isinstance(value, dict):
            return {k: normalize(v) for k, v in value.items()}
        if isinstance(value, list):
            return [normalize(v) for v in value]
        if isinstance(value, float) and value.is_integer():
            return int(value)
        return value

    canonical = json.dumps(normalize(payload), sort_keys=True, ensure_ascii=True,
                           separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class VisionEventLedger:
    def __init__(self, storage: FirebaseClient | None = None):
        # Explicit dependency injection is for tests. The runtime singleton uses
        # real-only storage and cannot silently accept a memory fallback.
        self._injected_storage = storage

    def commit(self, uid: str, request: VisionEnvelope, candidate: dict, validate_new) -> dict:
        storage = self._injected_storage or get_firebase_client()
        if self._injected_storage is None:
            try:
                if not storage.initialize() or storage.using_mock or not storage.settings.require_real_storage:
                    raise auth_error(503, "Vision receipt storage unavailable")
            except Exception:
                raise auth_error(503, "Vision receipt storage unavailable") from None
        key = event_key(str(request.visionEventId))
        digest = fingerprint(request)

        def transform(raw):
            if raw is None:
                raw = {"version": 1, "producerUid": uid}
            if not isinstance(raw, dict) or raw.get("version") != 1 or raw.get("producerUid") != uid:
                raise auth_error(503, "Vision receipt data is invalid")
            events, streams = raw.get("events", {}), raw.get("streams", {})
            if not isinstance(events, dict) or not isinstance(streams, dict):
                raise auth_error(503, "Vision receipt data is invalid")
            existing = events.get(key)
            if existing is not None:
                if not isinstance(existing, dict):
                    raise auth_error(503, "Vision receipt data is invalid")
                if existing.get("fingerprint") != digest:
                    raise auth_error(409, "VISION_EVENT_ID_CONFLICT")
                scope = ("producerUid", "visionEventId", "bindingId", "cameraId", "cameraEpoch",
                         "sessionId", "ownerUid", "sessionGeneration", "sourceType")
                if (any(existing.get(field) != candidate[field] for field in scope)
                        or not isinstance(existing.get("attemptId"), str)):
                    raise auth_error(503, "Vision receipt scope is invalid")
                try:
                    response = VisionReceipt.model_validate(existing["response"])
                    if (response.bindingId != request.bindingId or response.visionEventId != request.visionEventId
                            or response.receivedAt.tzinfo is None
                            or response.receivedAt != datetime.fromisoformat(existing["firstProcessedAt"])):
                        raise ValueError("Invalid stored response")
                except (ValueError, KeyError):
                    raise auth_error(503, "Vision receipt response is invalid") from None
                return raw
            previous = streams.get(str(request.bindingId))
            # Pure validation against every CAS snapshot, no model/HTTP side effects.
            validate_new(previous)
            updated = deepcopy(raw)
            updated.setdefault("events", {})[key] = {**candidate, "fingerprint": digest}
            updated.setdefault("streams", {})[str(request.bindingId)] = {
                "cameraId": request.cameraId, "cameraEpoch": str(request.cameraEpoch),
                "frameIndex": request.frameIndex,
                "capturedAt": request.capturedAt.astimezone(timezone.utc).isoformat(),
                "frameId": request.detectionResult.get("frameId"),
                "visionEventId": str(request.visionEventId),
                "receivedAt": candidate["firstProcessedAt"],
            }
            return updated

        try:
            committed = storage.transaction(producer_path(uid), transform)
            record = committed["events"][key]
            # Never return success from an unconfirmed write or a partial cache.
            if record.get("fingerprint") != digest:
                raise auth_error(503, "Vision receipt commit is unconfirmed")
            return record
        except HTTPException:
            raise
        except Exception:
            raise auth_error(503, "Vision receipt storage unavailable") from None
