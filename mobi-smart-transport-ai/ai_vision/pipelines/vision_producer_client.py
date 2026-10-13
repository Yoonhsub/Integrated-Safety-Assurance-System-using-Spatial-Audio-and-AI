"""Local-only v2 producer transport. No backend imports or administrator credentials."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from functools import lru_cache
import hashlib
import json
import math
from pathlib import Path
import threading
import time
from urllib.parse import urlsplit
from uuid import uuid4

import httpx
from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


class ProducerError(RuntimeError):
    """Sanitized error; never embeds request headers, credentials or server bodies."""

    def __init__(self, code: str, *, status: int | None = None, uncertain: bool = False):
        super().__init__(code)
        self.code, self.status, self.uncertain = code, status, uncertain


def _loopback(url: str) -> str:
    parsed = urlsplit(url)
    if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port
            or parsed.username or parsed.password or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment):
        raise ValueError("Local client requires http://127.0.0.1:<port>")
    return url.rstrip("/")


def _positive(value: float):
    if isinstance(value, bool) or not math.isfinite(value) or value <= 0:
        raise ValueError("Expected a finite positive limit")


def _timestamp(value: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError("Expected timezone-aware ISO timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Expected timezone-aware ISO timestamp")
    return result


@lru_cache(maxsize=2)
def _validator(name: str):
    root = Path(__file__).resolve().parents[2] / "packages/shared_contracts/api"
    schemas = {p.name: json.loads(p.read_text(encoding="utf-8")) for p in
               (root / name, root / "vision_detection.response.schema.json")}
    registry = Registry().with_resources((key, Resource.from_contents(value))
                                         for key, value in schemas.items())
    return Draft202012Validator(schemas[name], registry=registry, format_checker=FormatChecker())


class EmulatorProducerAuth:
    """Password used once; refresh token held only in memory. Explicit demo boundary."""

    def __init__(self, *, project_id: str, emulator_url: str = "http://127.0.0.1:9099",
                 transport=None, clock=time.monotonic, refresh_margin: float = 60):
        if project_id != "demo-mobi-local":
            raise ValueError("Only demo-mobi-local is supported; production auth is not implemented")
        _positive(refresh_margin)
        self._http = httpx.Client(base_url=_loopback(emulator_url), transport=transport,
                                  timeout=5, trust_env=False, follow_redirects=False)
        self._clock, self._margin = clock, refresh_margin
        self._lock = threading.RLock()
        self._token = self._refresh = self._uid = None
        self._deadline = 0.0

    @property
    def uid(self):
        with self._lock:
            if not self._uid:
                raise ProducerError("AUTH_LOGIN_REQUIRED")
            return self._uid

    def _exchange(self, path, **kwargs):
        try:
            response = self._http.post(path, params={"key": "demo-local"}, **kwargs)
            if response.status_code != 200:
                raise ProducerError("AUTH_REJECTED" if response.status_code < 500 else "AUTH_UNAVAILABLE",
                                    status=response.status_code)
            return response.json()
        except ProducerError:
            raise
        except (httpx.HTTPError, ValueError):
            raise ProducerError("AUTH_UNAVAILABLE") from None

    def _install(self, body, *, refresh=False):
        try:
            token, renewal, uid, lifetime = (body[k] for k in
                (("id_token", "refresh_token", "user_id", "expires_in") if refresh else
                 ("idToken", "refreshToken", "localId", "expiresIn")))
            if not all(isinstance(v, str) and v.strip() for v in (token, renewal, uid)):
                raise ValueError()
            lifetime = float(lifetime)
            _positive(lifetime)
            if refresh and uid != self._uid:
                raise ValueError()
        except (KeyError, TypeError, ValueError):
            self._token = self._refresh = None
            raise ProducerError("AUTH_INVALID_RESPONSE") from None
        self._token, self._refresh, self._uid = token, renewal, uid
        self._deadline = self._clock() + lifetime

    def login(self, email: str, password: str):
        with self._lock:
            self._token = self._refresh = self._uid = None
            self._install(self._exchange("/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword",
                json={"email": email, "password": password, "returnSecureToken": True}))

    def token(self, *, force_refresh=False) -> str:
        with self._lock:
            if not self._refresh:
                raise ProducerError("AUTH_LOGIN_REQUIRED")
            if force_refresh or self._clock() >= self._deadline - self._margin:
                self._token = None  # failed renewal must not silently use a cached token
                self._install(self._exchange("/securetoken.googleapis.com/v1/token",
                    data={"grant_type": "refresh_token", "refresh_token": self._refresh}), refresh=True)
            return self._token

    def close(self):
        with self._lock:
            self._token = self._refresh = self._uid = None
            self._http.close()


@dataclass(frozen=True)
class VisionEvent:
    """Serialized bytes own a deep snapshot; callers only receive decoded copies."""
    body: bytes = field(repr=False)

    def __post_init__(self):
        if not isinstance(self.body, bytes):
            raise ValueError("Event body must be immutable bytes")
        data = self.payload()
        _validator("vision_v2.request.schema.json").validate(data)
        detection = data["detectionResult"]
        expected = "webcam" if data["sourceType"] == "live" else "video_file"
        if detection["source"] != expected:
            raise ValueError("Source mode mismatch")
        captured = _timestamp(data["capturedAt"])
        if detection.get("capturedAt") and _timestamp(detection["capturedAt"]) != captured:
            raise ValueError("Capture timestamp mismatch")
        for item in detection["detections"]:
            box = item["bbox"]
            if (not all(math.isfinite(n) for n in [item["confidence"], *box.values()])
                    or box["x"] + box["w"] > 1.000000001 or box["y"] + box["h"] > 1.000000001):
                raise ValueError("Invalid normalized detection bbox")

    def payload(self):
        return json.loads(self.body)

    @property
    def digest(self):
        """Wire-byte digest, distinct from the server's semantic fingerprint."""
        return hashlib.sha256(self.body).hexdigest()

    @classmethod
    def create(cls, binding: dict, detection_result, *, frame_index: int, captured_at: str,
               capture_clock: str = "unknown", event_id: str | None = None):
        detection = detection_result.to_dict() if hasattr(detection_result, "to_dict") else detection_result
        payload = {k: binding[k] for k in
                   ("producerId", "cameraId", "sessionId", "bindingId", "cameraEpoch", "sourceType")}
        payload.update(envelopeVersion="2.0.0", visionEventId=event_id or str(uuid4()),
                       frameIndex=frame_index, capturedAt=captured_at, captureClock=capture_clock,
                       detectionResult=detection)
        return cls(json.dumps(payload, sort_keys=True, separators=(",", ":"),
                              allow_nan=False).encode("utf-8"))


@dataclass(frozen=True)
class RetryPolicy:
    max_attempts: int = 3
    initial_delay: float = 0.1
    max_delay: float = 1.0
    max_elapsed: float = 4.0
    event_max_age: float = 4.0
    request_timeout: float = 2.0

    def __post_init__(self):
        if type(self.max_attempts) is not int or not 1 <= self.max_attempts <= 10:
            raise ValueError("max_attempts must be 1..10")
        for value in (self.initial_delay, self.max_delay, self.max_elapsed,
                      self.event_max_age, self.request_timeout):
            _positive(value)


@dataclass
class _Camera:
    binding: dict
    lock: threading.RLock = field(default_factory=threading.RLock)
    high_index: int = -1
    pending: VisionEvent | None = None
    disabled: bool = False
    acknowledged: dict[str, int] = field(default_factory=dict)
    pending_deadline: float | None = None


class VisionProducerClient:
    """One in-flight event per camera; uncertain pending events block new frames."""

    def __init__(self, backend_url: str, auth: EmulatorProducerAuth, *, policy=None,
                 transport=None, clock=time.monotonic, utc_clock=None, sleep=time.sleep):
        self.auth, self.policy = auth, policy or RetryPolicy()
        self._http = httpx.Client(base_url=_loopback(backend_url), transport=transport,
                                  trust_env=False, follow_redirects=False)
        self._clock, self._utc = clock, utc_clock or (lambda: datetime.now(timezone.utc))
        self._sleep = sleep
        self._cameras, self._lock = {}, threading.RLock()

    def attach_binding(self, binding: dict):
        # Caller supplies the server-admin-created binding, never client-generated permissions.
        owned = json.loads(json.dumps(binding))
        if owned["producerId"] != self.auth.uid:
            raise ProducerError("BINDING_PRODUCER_MISMATCH")
        with self._lock:
            camera = self._cameras.get(owned["cameraId"])
            if camera is None:
                self._cameras[owned["cameraId"]] = _Camera(owned)
                return
        with camera.lock:
            if (camera.binding["bindingId"], camera.binding["cameraEpoch"]) == (owned["bindingId"], owned["cameraEpoch"]):
                return  # reattaching cannot erase an uncertain pending event
            if camera.binding["cameraEpoch"] == owned["cameraEpoch"]:
                raise ProducerError("NEW_BINDING_REQUIRES_NEW_EPOCH")
            camera.binding, camera.high_index, camera.pending, camera.disabled = owned, -1, None, False
            camera.acknowledged.clear()
            camera.pending_deadline = None

    def send(self, event: VisionEvent):
        data = event.payload()
        with self._lock:
            camera = self._cameras.get(data["cameraId"])
        if camera is None:
            raise ProducerError("BINDING_NOT_ATTACHED")
        with camera.lock:
            scope = ("producerId", "cameraId", "sessionId", "bindingId", "cameraEpoch", "sourceType")
            if (camera.disabled or data["producerId"] != self.auth.uid
                    or any(data[k] != camera.binding[k] for k in scope)):
                raise ProducerError("BINDING_INVALIDATED")
            if camera.pending is not None and camera.pending.body != event.body:
                raise ProducerError("PREVIOUS_EVENT_UNCERTAIN", uncertain=True)
            if camera.pending is None and data["frameIndex"] <= camera.high_index:
                # Re-send of a previously acknowledged event is allowed. The server's
                # ledger distinguishes it from a new ID with the same/older frame.
                if event.digest not in camera.acknowledged:
                    raise ProducerError("FRAME_ORDER_REJECTED")
            start = self._clock()
            remaining = self.policy.event_max_age - (self._utc() - _timestamp(data["capturedAt"])).total_seconds()
            deadline = start + min(self.policy.max_elapsed, remaining)
            if camera.pending_deadline is not None:
                deadline = min(deadline, camera.pending_deadline)
            refreshed, refresh_used, uncertain = False, False, camera.pending is not None
            for attempt in range(self.policy.max_attempts):
                if self._clock() >= deadline:
                    raise ProducerError("EVENT_EXPIRED" if remaining <= self.policy.max_elapsed else "RETRY_BUDGET_EXHAUSTED",
                                        uncertain=uncertain)
                try:
                    token = self.auth.token(force_refresh=refreshed)
                    refreshed = False
                except ProducerError as exc:
                    raise ProducerError(exc.code, status=exc.status, uncertain=uncertain) from None
                if self._clock() >= deadline:
                    raise ProducerError("EVENT_EXPIRED", uncertain=uncertain)
                camera.pending = event
                camera.pending_deadline = deadline
                try:
                    response = self._http.post("/ai-vision/v2/events", content=event.body,
                        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
                        timeout=min(self.policy.request_timeout, deadline - self._clock()))
                except httpx.RequestError:
                    response = None
                    uncertain = True
                if response is not None:
                    status = response.status_code
                    if status == 202:
                        try:
                            result = response.json()
                            _validator("vision_v2.response.schema.json").validate(result)
                            if (result["visionEventId"] != data["visionEventId"] or result["bindingId"] != data["bindingId"]
                                    or result.get("accepted") is not True
                                    or any(result.get(k) is not False for k in
                                           ("stored", "guidanceEligible", "freshnessVerified"))):
                                raise ValueError()
                        except Exception:
                            raise ProducerError("INVALID_RECEIPT", uncertain=True) from None
                        camera.high_index = max(camera.high_index, data["frameIndex"])
                        camera.pending, camera.pending_deadline = None, None
                        camera.acknowledged[event.digest] = data["frameIndex"]
                        if len(camera.acknowledged) > 128:
                            del camera.acknowledged[next(iter(camera.acknowledged))]
                        return result
                    if status == 401 and not refresh_used:
                        refresh_used = True
                        refreshed = True
                        if not uncertain:
                            camera.pending, camera.pending_deadline = None, None
                    elif status != 503:
                        camera.pending = None
                        camera.pending_deadline = None
                        if status in (401, 403):
                            camera.disabled = True
                        code = "HTTP_REJECTED"
                        if status == 409:
                            # Whitelist machine-readable reasons; never echo arbitrary
                            # server text that might contain request data or secrets.
                            reasons = {"VISION_EVENT_ID_CONFLICT": "EVENT_ID_CONFLICT",
                                "Duplicate or out-of-order frameIndex": "FRAME_ORDER_REJECTED",
                                "Capture timestamp moved backwards": "CAPTURE_ORDER_REJECTED",
                                "Frame identity was already accepted": "FRAME_ID_REJECTED",
                                "Capture timestamp is too far in the future": "FUTURE_FRAME_REJECTED",
                                "Frame is too old": "OLD_FRAME_REJECTED"}
                            try: code = reasons.get(response.json().get("detail"), code)
                            except (ValueError, AttributeError, TypeError): pass
                        raise ProducerError(code, status=status, uncertain=uncertain)
                    if status == 503:
                        uncertain = True
                if attempt + 1 == self.policy.max_attempts:
                    if not uncertain:
                        raise ProducerError("HTTP_REJECTED", status=response.status_code)
                    raise ProducerError("DELIVERY_UNCERTAIN", uncertain=True)
                delay = min(self.policy.initial_delay * 2 ** attempt, self.policy.max_delay)
                if self._clock() + delay >= deadline:
                    raise ProducerError("EVENT_EXPIRED", uncertain=True)
                self._sleep(delay)
            raise AssertionError("Unreachable")

    def close(self):
        self._http.close()
