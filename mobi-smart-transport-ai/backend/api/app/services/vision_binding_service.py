"""Fail-closed local bindings; no durable safety observations or Live delivery."""
import math
import os
from typing import Callable

from fastapi import HTTPException
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from threading import RLock
from time import monotonic
from uuid import uuid4

from app.local_emulator import validate_local_emulators
from app.schemas.vision_v2 import BindingCreate, CameraRegistration, VisionEnvelope, VisionReceipt
from app.security import auth_error, require_role, valid_key
from app.services.v3_guidance_store import V3GuidanceStore, v3_guidance_store
from app.services.vision_event_ledger import VisionEventLedger


def require_local_vision() -> None:
    try:
        validate_local_emulators()
    except ValueError:
        raise auth_error(503, "Vision v2 requires the isolated local emulator environment") from None


@dataclass(frozen=True)
class Binding:
    binding_id: str
    camera_id: str
    producer_id: str
    session_id: str
    owner_uid: str
    session_generation: str
    epoch: str
    source_type: str
    expires_at: datetime
    deadline: float
    started_mono: float

    def public(self) -> dict:
        return {
            "bindingId": self.binding_id, "cameraId": self.camera_id,
            "producerId": self.producer_id, "sessionId": self.session_id,
            "cameraEpoch": self.epoch, "sourceType": self.source_type,
            "expiresAt": self.expires_at.isoformat(),
        }


@dataclass(frozen=True)
class FreshnessPolicy:
    """Uncalibrated local-demo limits; not validated safety thresholds."""
    max_age: float = 5.0
    future_skew: float = 1.0
    observation_ttl: float = 3.0
    connection_timeout: float = 5.0

    @classmethod
    def from_environment(cls):
        names = ("MOBI_VISION_MAX_FRAME_AGE_SEC", "MOBI_VISION_FUTURE_SKEW_SEC",
                 "MOBI_VISION_OBSERVATION_TTL_SEC", "MOBI_VISION_CONNECTION_TIMEOUT_SEC")
        try:
            values = [float(os.getenv(name, str(default))) for name, default in
                      zip(names, (5.0, 1.0, 3.0, 5.0))]
            if any(not math.isfinite(v) for v in values) or values[1] < 0 or any(values[i] <= 0 for i in (0, 2, 3)):
                raise ValueError("Invalid vision timing policy")
            return cls(*values)
        except ValueError:
            raise auth_error(503, "Vision timing policy is invalid") from None


@dataclass
class Observation:
    frame_index: int
    frame_id: str | None
    captured_at: datetime
    received_at: datetime
    received_mono: float
    deadline: float
    status: str
    capture_clock: str
    expired: bool = False
    lost: bool = False
    clock_error: bool = False
    preview: dict | None = None


class VisionBindingService:
    """One-process authority, intentionally invalid after restart.

    Lock order is binding lock then session lock. Session lifecycle operations
    use only the latter, so reset/close and acceptance have a linearization point.
    """

    def __init__(self, sessions: V3GuidanceStore = v3_guidance_store, *,
                 policy: FreshnessPolicy | None = None,
                 utc_clock: Callable[[], datetime] | None = None,
                 mono_clock: Callable[[], float] | None = None,
                 storage=None):
        self.sessions = sessions
        self.ledger = VisionEventLedger(storage)
        self.policy = policy
        self._utc_clock = utc_clock
        self._mono_clock = mono_clock
        self._lock = RLock()
        self._cameras: dict[str, CameraRegistration] = {}
        self._bindings: dict[str, Binding] = {}
        self._observations: dict[str, Observation] = {}

    def _now(self):
        return self._utc_clock() if self._utc_clock else datetime.now(timezone.utc)

    def _mono(self):
        return self._mono_clock() if self._mono_clock else monotonic()

    def _policy(self):
        return self.policy or FreshnessPolicy.from_environment()

    def _expire(self, observation: Observation, now: datetime, mono: float, policy: FreshnessPolicy):
        elapsed = mono - observation.received_mono
        wall_elapsed = (now - observation.received_at).total_seconds()
        if elapsed < 0 or abs(wall_elapsed - elapsed) > policy.future_skew:
            observation.clock_error = True
        if observation.clock_error or mono >= observation.deadline or (now - observation.captured_at).total_seconds() >= policy.max_age:
            observation.expired = True
        if observation.clock_error or elapsed >= policy.connection_timeout:
            observation.lost = True
        if observation.lost:
            observation.expired = True


    def register(self, camera_id: str, registration: CameraRegistration) -> dict:
        require_local_vision()
        require_role("admin")
        if not valid_key(camera_id):
            raise auth_error(422, "Invalid camera identifier")
        with self._lock:
            self._cameras[camera_id] = registration.model_copy(deep=True)
            # Even re-registering the same camera invalidates its old epoch.
            self._bindings.pop(camera_id, None)
            self._observations.pop(camera_id, None)
        return {"cameraId": camera_id, **registration.model_dump()}

    def bind(self, request: BindingCreate) -> dict:
        require_local_vision()
        require_role("admin")
        with self._lock, self.sessions.vision_scope(request.sessionId) as session:
            camera = self._cameras.get(request.cameraId)
            if camera is None:
                raise auth_error(403, "Camera is not registered")
            binding = Binding(
                str(uuid4()), request.cameraId, camera.producerId, session.session_id,
                session.owner_uid, session.vision_generation, str(uuid4()), camera.sourceType,
                self._now() + timedelta(seconds=request.ttlSeconds),
                self._mono() + request.ttlSeconds, self._mono(),
            )
            self._bindings[request.cameraId] = binding
            self._observations.pop(request.cameraId, None)
            return binding.public()

    def revoke(self, camera_id: str, binding_id: str) -> None:
        require_local_vision()
        require_role("admin")
        with self._lock:
            binding = self._bindings.get(camera_id)
            if binding is None or binding.binding_id != binding_id:
                raise auth_error(403, "Binding is not active")
            del self._bindings[camera_id]
            self._observations.pop(camera_id, None)

    def accept(self, request: VisionEnvelope) -> VisionReceipt:
        require_local_vision()
        principal = require_role("vision_producer")
        # Administrators configure bindings; they do not impersonate producers.
        if principal.role != "vision_producer" or principal.uid != request.producerId:
            raise auth_error(403, "Producer identity mismatch")
        with self._lock:
            binding = self._bindings.get(request.cameraId)
            if binding is None or (
                binding.producer_id != principal.uid
                or binding.binding_id != str(request.bindingId)
                or binding.epoch != str(request.cameraEpoch)
                or binding.session_id != request.sessionId
                or binding.source_type != request.sourceType
            ):
                raise auth_error(403, "Binding access denied")
            with self.sessions.vision_scope(binding.session_id) as session:
                now = self._now()
                mono = self._mono()
                if (session.owner_uid != binding.owner_uid
                        or session.vision_generation != binding.session_generation
                        or mono >= binding.deadline or now >= binding.expires_at):
                    raise auth_error(403, "Binding expired or invalidated")
                policy = self._policy()
                local_previous = self._observations.get(request.cameraId)
                age = (now - request.capturedAt).total_seconds()

                def validate_new(durable_previous):
                    # Scope lifecycle changes are blocked by these locks. Time
                    # expiry is checked on each SDK retry; no callback side effects.
                    if self._mono() >= binding.deadline or self._now() >= binding.expires_at:
                        raise auth_error(403, "Binding expired or invalidated")
                    if local_previous and request.sourceType == "live":
                        elapsed = mono - local_previous.received_mono
                        wall_elapsed = (now - local_previous.received_at).total_seconds()
                        if local_previous.clock_error or elapsed < 0 or abs(wall_elapsed - elapsed) > policy.future_skew:
                            raise auth_error(503, "Server clock changed; reconnect camera")
                    snapshots = []
                    if local_previous:
                        snapshots.append((local_previous.frame_index, local_previous.captured_at, local_previous.frame_id))
                    if durable_previous is not None:
                        try:
                            if (durable_previous["cameraId"] != request.cameraId
                                    or durable_previous["cameraEpoch"] != str(request.cameraEpoch)
                                    or type(durable_previous["frameIndex"]) is not int):
                                raise ValueError("Invalid watermark")
                            capture = datetime.fromisoformat(durable_previous["capturedAt"])
                            if capture.tzinfo is None:
                                raise ValueError("Invalid watermark timestamp")
                            snapshots.append((durable_previous["frameIndex"], capture, durable_previous.get("frameId")))
                        except (KeyError, ValueError, TypeError):
                            raise auth_error(503, "Vision watermark data is invalid") from None
                    for index, capture, frame_id in snapshots:
                        if request.frameIndex <= index:
                            raise auth_error(409, "Duplicate or out-of-order frameIndex")
                        if request.capturedAt < capture:
                            raise auth_error(409, "Capture timestamp moved backwards")
                        if frame_id is not None and frame_id == request.detectionResult.get("frameId"):
                            raise auth_error(409, "Frame identity was already accepted")
                    if request.sourceType == "live":
                        if age < -policy.future_skew:
                            raise auth_error(409, "Capture timestamp is too far in the future")
                        if age >= policy.max_age:
                            raise auth_error(409, "Frame is too old")

                result = request.detectionResult
                status = result["status"]
                # These describe only the declared frame, never a safe situation.
                outcome = ("observed" if result["detections"] else "no_detection") if status == "ok" else status
                if request.sourceType == "replay":
                    outcome = "ineligible"
                lifetime = min(policy.observation_ttl, max(0.0, policy.max_age - max(0.0, age)))
                if status != "ok":
                    lifetime = 0.0
                receipt = VisionReceipt(visionEventId=request.visionEventId,
                                        bindingId=request.bindingId, receivedAt=now)
                attempt_id = str(uuid4())
                candidate = {
                    "producerUid": principal.uid, "visionEventId": str(request.visionEventId),
                    "cameraId": request.cameraId, "bindingId": binding.binding_id,
                    "cameraEpoch": binding.epoch, "sessionId": binding.session_id,
                    "ownerUid": binding.owner_uid, "sessionGeneration": binding.session_generation,
                    "sourceType": request.sourceType, "frameIndex": request.frameIndex,
                    "firstProcessedAt": now.isoformat(), "bindingExpiresAt": binding.expires_at.isoformat(),
                    "retentionPolicy": "retain-no-automatic-deletion",
                    "attemptId": attempt_id, "response": receipt.model_dump(mode="json"),
                }
                # Only observational, server-selected wording. COCO bus is the
                # sole display class; no door/stop/boarding claims are projected.
                classes = ["bus"] if status == "ok" and any(
                    d["classId"] == "bus" for d in result["detections"]
                ) else []
                preview = dict(sessionId=binding.session_id, producerId=principal.uid,
                    cameraId=request.cameraId, cameraEpoch=binding.epoch,
                    visionEventId=str(request.visionEventId), frameIndex=request.frameIndex,
                    sourceType=request.sourceType, capturedAt=request.capturedAt.isoformat(),
                    receivedAt=now.isoformat(), captureClock=request.captureClock,
                    observedClasses=classes,
                    message="버스가 감지되었습니다" if classes else "현재 관찰된 대상 객체가 없습니다",
                    inferenceStatus=status)
                record = self.ledger.commit(principal.uid, request, candidate, validate_new,
                                            observation=preview)
                if record["attemptId"] == attempt_id:
                    # Cache is only a projection of a CONFIRMED atomic commit.
                    # An uncertain commit leaves this empty/old, never refreshed.
                    self._observations[request.cameraId] = Observation(
                        request.frameIndex, result.get("frameId"), request.capturedAt, now,
                        mono, mono + lifetime, outcome, request.captureClock,
                        preview=preview,
                    )
                # Duplicates return the original response without cache/TTL change,
                # even when newer frames have advanced the persisted watermark.
                return VisionReceipt.model_validate(record["response"])

    def preview(self, session_id: str) -> dict:
        """Read-only display projection; never feeds guidance or safety events."""
        require_local_vision()
        require_role("passenger")
        with self._lock, self.sessions.observation_scope(session_id) as session:
            now, mono, policy = self._now(), self._mono(), self._policy()
            items = []
            for binding in self._bindings.values():
                if (binding.session_id != session.session_id or binding.owner_uid != session.owner_uid
                        or binding.session_generation != session.vision_generation
                        or mono >= binding.deadline or now >= binding.expires_at):
                    continue
                observation = self._observations.get(binding.camera_id)
                if observation is None or observation.preview is None:
                    # No confirmed commit means no object/message can be exposed.
                    continue
                elapsed = mono - observation.received_mono
                wall_elapsed = (now - observation.received_at).total_seconds()
                invalid_clock = elapsed < 0 or abs(wall_elapsed - elapsed) > policy.future_skew
                if invalid_clock:
                    observation.clock_error = True
                ttl = (policy.observation_ttl - elapsed if binding.source_type == "replay"
                       else observation.deadline - mono)
                lost = observation.clock_error or elapsed >= policy.connection_timeout or observation.status == "unavailable"
                state = "lost" if lost else "expired" if ttl <= 0 or observation.preview["inferenceStatus"] != "ok" else "available"
                remaining = max(0.0, min(ttl, binding.deadline - mono,
                                        (binding.expires_at - now).total_seconds())) if state == "available" else 0.0
                value = dict(observation.preview, state=state, validForSeconds=remaining,
                             freshnessVerified=False, guidanceEligible=False)
                if state != "available":
                    value.update(observedClasses=[], message="카메라 연결이 중단되었습니다" if lost else "현재 관찰 정보가 없습니다")
                items.append(value)
            return dict(sessionId=session.session_id, observations=sorted(items, key=lambda x: x["cameraId"]))


    def state(self, camera_id: str) -> dict:
        require_local_vision()
        principal = require_role("vision_producer", "admin")
        with self._lock:
            camera = self._cameras.get(camera_id)
            if camera is None or (principal.role != "admin" and camera.producerId != principal.uid):
                raise auth_error(403, "Camera access denied")
            binding = self._bindings.get(camera_id)
            value = {"cameraId": camera_id, "bindingStatus": "inactive", "connectionStatus": "closed",
                     "observationStatus": "unknown", "freshnessVerified": False, "guidanceEligible": False,
                     "sourceType": camera.sourceType, "cameraEpoch": None, "lastFrameIndex": None,
                     "lastCapturedAt": None, "lastReceivedAt": None, "captureClock": "unknown"}
            if binding is None:
                return value
            now, mono = self._now(), self._mono()
            value.update(cameraEpoch=binding.epoch, bindingStatus="active", connectionStatus="waiting")
            try:
                with self.sessions.vision_scope(binding.session_id) as session:
                    if session.vision_generation != binding.session_generation or session.owner_uid != binding.owner_uid:
                        value["bindingStatus"] = "invalidated"
                    if mono >= binding.deadline or now >= binding.expires_at:
                        value["bindingStatus"] = "expired"
                    if value["bindingStatus"] != "active":
                        value["connectionStatus"] = "closed"
                        return value
                    observation = self._observations.get(camera_id)
                    if observation is None:
                        elapsed = mono - binding.started_mono
                        if elapsed < 0 or elapsed >= self._policy().connection_timeout:
                            value["connectionStatus"] = "lost"
                        return value
                    value.update(lastFrameIndex=observation.frame_index,
                                 lastCapturedAt=observation.captured_at.isoformat(),
                                 lastReceivedAt=observation.received_at.isoformat(), captureClock=observation.capture_clock)
                    if camera.sourceType == "replay":
                        value.update(connectionStatus="replay", observationStatus="ineligible")
                        return value
                    self._expire(observation, now, mono, self._policy())
                    connection = "lost" if observation.lost or observation.status == "unavailable" else "connected"
                    state = "expired" if observation.expired else observation.status
                    # Failure information is not a normal empty-detection result.
                    if observation.status in {"error", "unavailable"}:
                        state = observation.status
                    value.update(connectionStatus=connection, observationStatus=state)
                    return value
            except HTTPException as exc:
                if exc.status_code != 403:
                    raise
                value.update(bindingStatus="invalidated", connectionStatus="closed")
                return value


vision_binding_service = VisionBindingService()
