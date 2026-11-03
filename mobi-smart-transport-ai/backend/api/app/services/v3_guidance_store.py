from __future__ import annotations

from contextlib import contextmanager
from uuid import uuid4
from secrets import token_urlsafe, token_bytes
import base64
import hashlib
import hmac
import json
from time import monotonic
import math
from dataclasses import dataclass, field
from threading import RLock
from datetime import datetime, timedelta, timezone
from typing import Callable, Any

from app.security import auth_error, require_role
from app.schemas.v3 import BeaconDecision, GuidanceSessionState, GuidanceState, new_session_id, utc_now


@dataclass
class V3SessionRecord:
    session_id: str
    owner_uid: str | None = None
    vision_generation: str = field(default_factory=lambda: str(uuid4()))
    vision_closed: bool = False
    vision_lease_id: str | None = None
    safety_sequence: int = 0
    safety_items: list[dict] = field(default_factory=list)
    safety_seen: set[str] = field(default_factory=set)
    safety_watermark: datetime | None = None
    wake_word: str = "자비스"
    state: GuidanceState = GuidanceState.IDLE
    selected_destination: str | None = None
    selected_route_no: str | None = None
    selected_route_id: str | None = None
    selected_stop_id: str | None = None
    selected_stop_name: str | None = None
    target_bus_id: str | None = None
    selected_plan_id: str | None = None
    origin_location: dict[str, float] | None = None
    nearby_boarding_stops: list[dict[str, Any]] = field(default_factory=list)
    nearby_alighting_stops: list[dict[str, Any]] = field(default_factory=list)
    recommended_plan: dict[str, Any] | None = None
    alternative_plans: list[dict[str, Any]] = field(default_factory=list)
    selected_plan: dict[str, Any] | None = None
    current_leg_index: int = 0
    pending_question: str | None = None
    pending_resolution_status: str | None = None
    pending_heard_text: str | None = None
    pending_top_candidate_name: str | None = None
    pending_choice_names: list[str] = field(default_factory=list)
    pending_origin_lat: float | None = None
    pending_origin_lng: float | None = None
    last_route_plan: dict[str, Any] | None = None
    conversation_history: list[dict[str, Any]] = field(default_factory=list)
    geofence_armed: bool = False
    last_decision: BeaconDecision | None = None
    # Internal freshness marker; not part of the public session contract.
    last_decision_at: datetime | None = None
    nearest_beacon: dict | None = None
    target_bus: dict | None = None
    updated_at: datetime = field(default_factory=utc_now)
    # Optional persistence hook invoked after every state change. Excluded from
    # equality/repr so it never affects API contracts or test comparisons.
    on_touch: Callable[["V3SessionRecord"], None] | None = field(
        default=None, repr=False, compare=False
    )

    def touch(self) -> None:
        self.updated_at = utc_now()
        if self.on_touch is not None:
            try:
                self.on_touch(self)
            except Exception:  # pragma: no cover - persistence is best-effort
                pass

    def to_response(self) -> GuidanceSessionState:
        return GuidanceSessionState(
            sessionId=self.session_id,
            state=self.state,
            wakeWord=self.wake_word,
            selectedDestination=self.selected_destination,
            selectedRouteNo=self.selected_route_no,
            selectedRouteId=self.selected_route_id,
            selectedStopId=self.selected_stop_id,
            selectedStopName=self.selected_stop_name,
            targetBusId=self.target_bus_id,
            selectedPlanId=self.selected_plan_id,
            pendingDestinationCandidates=list(self.pending_choice_names),
            originLocation=self.origin_location,
            nearbyBoardingStops=list(self.nearby_boarding_stops),
            nearbyAlightingStops=list(self.nearby_alighting_stops),
            recommendedPlan=self.recommended_plan,
            alternativePlans=list(self.alternative_plans),
            selectedPlan=self.selected_plan,
            currentLegIndex=self.current_leg_index,
            pendingQuestion=self.pending_question,
            pendingResolutionStatus=self.pending_resolution_status,
            geofenceArmed=self.geofence_armed,
            lastDecision=self.last_decision,
            nearestBeacon=self.nearest_beacon,
            targetBus=self.target_bus,
            updatedAt=self.updated_at,
        )


@dataclass
class PassengerVisionLease:
    lease_id: str
    owner_uid: str
    auth_time: float
    created_at: datetime
    expires_at: datetime
    deadline: float
    status: str = "active"
    operation_id: str | None = None
    version: int = 0


@dataclass
class VisionStartOperation:
    operation_id: str
    owner_uid: str
    auth_time: float
    version: int
    base_version: int
    fingerprint: str
    registered_at: datetime
    expires_at: datetime
    deadline: float
    status: str = "prepared"
    issue_fingerprint: str | None = None
    receipt: dict | None = None  # Internal Lease reference/metadata; no bearer or ticket.
    receipt_deadline: float | None = None


class V3GuidanceStore:
    """In-memory V3 session store for local demo/test startup safety.

    The in-memory map remains the source of truth for the session lifecycle so
    existing route contracts and tests are unaffected. As a best-effort
    enhancement, every session mutation is mirrored to the Realtime Database at
    ``/v3GuidanceSessions/{sessionId}`` via the shared FirebaseClient — this
    writes to the real RTDB when credentials are present and to the in-memory
    mock store otherwise. Persistence failures are swallowed and never break a
    request.
    """

    def __init__(self) -> None:
        self._sessions: dict[str, V3SessionRecord] = {}
        self._lock = RLock()
        self._vision_leases: dict[str, PassengerVisionLease] = {}
        self._vision_login_watermark: dict[str, float] = {}
        self._lease_clock = monotonic
        self._vision_operations: dict[tuple[str, str], VisionStartOperation] = {}
        self._vision_start_versions: dict[str, int] = {}
        self._vision_ticket_secret = token_bytes(32)
        self._vision_authority_epoch = token_urlsafe(16)

    def _lease_principal(self):
        principal = require_role("passenger")
        if (principal.role != "passenger" or isinstance(principal.auth_time, bool)
                or not isinstance(principal.auth_time, (int, float))
                or not math.isfinite(principal.auth_time) or principal.auth_time <= 0):
            raise auth_error(401, "Verified passenger login time required for Vision lease")
        return principal

    def _invalidate_lease(self, lease, state):
        # Prepare UUID work before mutation; issue also has a full rollback guard.
        plan = [(record, str(uuid4())) for record in self._sessions.values()
                if record.vision_lease_id == lease.lease_id]
        lease.status = state
        for record, generation in plan:
            record.vision_closed = True
            record.vision_generation = generation
        operation = self._vision_operations.get((lease.owner_uid, lease.operation_id))
        if operation is not None:
            operation.status = state
            operation.receipt = None

    def _active_lease(self, uid, lease_id, *, retire_expired=True):
        lease = self._vision_leases.get(uid)
        if lease is None or not lease_id or lease.lease_id != lease_id:
            raise auth_error(403, "Vision lease access denied")
        if lease.status == "active" and (self._lease_clock() >= lease.deadline or datetime.now(timezone.utc) >= lease.expires_at):
            if not retire_expired:
                raise auth_error(403, "Vision lease expired")
            self._invalidate_lease(lease, "expired")
        if lease.status != "active":
            raise auth_error(403, "Vision lease is not active")
        return lease

    def _owned_lease(self):
        principal = self._lease_principal()
        lease = self._active_lease(principal.uid, principal.vision_lease)
        if principal.auth_time != lease.auth_time:
            raise auth_error(403, "Vision login scope changed")
        return lease

    @staticmethod
    def _vision_fingerprint(value):
        return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                         allow_nan=False).encode()).hexdigest()

    def _operation_ticket(self, op):
        scope = [self._vision_authority_epoch, op.owner_uid, op.auth_time,
                 op.operation_id, op.version, op.base_version, op.expires_at.isoformat()]
        digest = hmac.new(self._vision_ticket_secret, json.dumps(scope).encode(), hashlib.sha256).digest()
        return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")

    def _operation_response(self, op):
        return dict(operationId=op.operation_id, startTicket=self._operation_ticket(op),
                    version=op.version, activeVersion=op.base_version,
                    registeredAt=op.registered_at, expiresAt=op.expires_at)

    def _prune_vision_receipts(self, uid):
        # Retain bounded tombstones for this process authority. Unknown keys NEVER
        # fall through to issuance. Capacity exhaustion rejects registrations.
        now, mono = datetime.now(timezone.utc), self._lease_clock()
        for (owner, _), op in self._vision_operations.items():
            if owner != uid:
                continue
            if (op.receipt is not None and
                    (mono >= op.receipt_deadline or now >= op.receipt["expiresAt"])):
                op.receipt = None
                if op.status == "issued":
                    op.status = "receipt-expired"
            if op.status == "prepared" and (mono >= op.deadline or now >= op.expires_at):
                op.status = "expired"

    def _issued_vision_response(self, op):
        lease = self._vision_leases.get(op.owner_uid)
        if (op.status != "issued" or op.receipt is None or lease is None
                or lease.operation_id != op.operation_id or lease.version != op.version
                or lease.status != "active" or self._lease_clock() >= lease.deadline
                or datetime.now(timezone.utc) >= lease.expires_at):
            raise auth_error(410, "Vision operation is no longer active")
        # Lease ID lives only in the authoritative Lease, never in the receipt.
        return dict(leaseId=lease.lease_id, ownerUid=op.owner_uid,
                    createdAt=op.receipt["createdAt"], expiresAt=op.receipt["expiresAt"],
                    status="active", version=op.version)

    def register_vision_operation(self, request):
        """Server REGISTER order is authority, not physical device login order."""
        principal = self._lease_principal()
        key = (principal.uid, str(request.operationId))
        digest = self._vision_fingerprint(request.model_dump(mode="json"))
        with self._lock:
            self._prune_vision_receipts(principal.uid)
            existing = self._vision_operations.get(key)
            if existing is not None:
                if existing.auth_time != principal.auth_time:
                    raise auth_error(403, "Vision operation scope denied")
                if existing.fingerprint != digest:
                    raise auth_error(409, "Vision operation request conflict")
                if existing.status == "issued":
                    self._issued_vision_response(existing)
                elif (existing.status != "prepared" or
                      existing.version != self._vision_start_versions.get(principal.uid)):
                    raise auth_error(410, "Vision operation was retired")
                return self._operation_response(existing)
            if principal.auth_time < self._vision_login_watermark.get(principal.uid, 0):
                raise auth_error(403, "Older login cannot start Vision operation")
            owned = [op for (uid, _), op in self._vision_operations.items() if uid == principal.uid]
            if len(owned) >= 1024:
                raise auth_error(503, "Vision operation capacity reached")
            active = self._vision_leases.get(principal.uid)
            base = active.version if active else 0
            if request.expectedActiveVersion is not None and request.expectedActiveVersion != base:
                raise auth_error(409, "Vision active version changed")
            version = self._vision_start_versions.get(principal.uid, 0) + 1
            now = datetime.now(timezone.utc)
            op = VisionStartOperation(str(request.operationId), principal.uid, principal.auth_time,
                                      version, base, digest, now, now + timedelta(seconds=900),
                                      self._lease_clock() + 900)
            old_version = self._vision_start_versions.get(principal.uid)
            old_watermark = self._vision_login_watermark.get(principal.uid)
            states = [(previous, previous.status) for previous in owned]
            try:
                response = self._operation_response(op)
                for previous in owned:
                    if previous.status == "prepared":
                        previous.status = "superseded"
                self._vision_operations[key] = op
                self._vision_start_versions[principal.uid] = version
                self._vision_login_watermark[principal.uid] = principal.auth_time
            except Exception:
                self._vision_operations.pop(key, None)
                for previous, state in states:
                    previous.status = state
                for mapping, old_value in ((self._vision_start_versions, old_version),
                                           (self._vision_login_watermark, old_watermark)):
                    if old_value is None:
                        mapping.pop(principal.uid, None)
                    else:
                        mapping[principal.uid] = old_value
                raise auth_error(503, "Vision registration unavailable") from None
            return response

    def _install_vision_issue(self, op, lease, receipt, digest):
        old = self._vision_leases.get(op.owner_uid)
        old_status = old.status if old else None
        records = [(r, r.vision_closed, r.vision_generation) for r in self._sessions.values()]
        snapshots = [(other, dict(other.__dict__)) for (uid, _), other in self._vision_operations.items()
                     if uid == op.owner_uid]
        try:
            if old is not None:
                self._invalidate_lease(old, "revoked")
            self._vision_leases[op.owner_uid] = lease
            op.status = "issued"
            op.issue_fingerprint = digest
            op.receipt = receipt
            op.receipt_deadline = lease.deadline
        except Exception:
            if old is None:
                self._vision_leases.pop(op.owner_uid, None)
            else:
                self._vision_leases[op.owner_uid] = old
                old.status = old_status
            for record, closed, generation in records:
                record.vision_closed, record.vision_generation = closed, generation
            for other, snapshot in snapshots:
                other.__dict__.clear()
                other.__dict__.update(snapshot)
            raise auth_error(503, "Vision issuance unavailable") from None

    def begin_vision_lease(self, request):
        principal = self._lease_principal()
        with self._lock:
            self._prune_vision_receipts(principal.uid)
            op = self._vision_operations.get((principal.uid, str(request.operationId)))
            if op is None or op.auth_time != principal.auth_time:
                raise auth_error(403, "Vision operation scope denied")
            digest = self._vision_fingerprint(request.model_dump(mode="json"))
            if op.issue_fingerprint is not None and op.issue_fingerprint != digest:
                raise auth_error(409, "Vision operation request conflict")
            if request.version != op.version or not hmac.compare_digest(request.startTicket, self._operation_ticket(op)):
                raise auth_error(403, "Vision start ticket denied")
            if op.status == "issued":
                return self._issued_vision_response(op)
            if op.status != "prepared":
                raise auth_error(410, "Vision operation was retired")
            current = self._vision_leases.get(principal.uid)
            current_version = current.version if current else 0
            if (op.version != self._vision_start_versions.get(principal.uid)
                    or current_version != op.base_version):
                raise auth_error(409, "Vision start version changed")
            try:
                now = datetime.now(timezone.utc)
                lease = PassengerVisionLease(token_urlsafe(32), principal.uid, principal.auth_time,
                                             now, now + timedelta(seconds=900), self._lease_clock() + 900,
                                             operation_id=op.operation_id, version=op.version)
                receipt = dict(leaseRef=op.operation_id, createdAt=now, expiresAt=lease.expires_at,
                               version=op.version)
                response = dict(leaseId=lease.lease_id, ownerUid=principal.uid, createdAt=now,
                                expiresAt=lease.expires_at, status="active", version=op.version)
            except Exception:
                raise auth_error(503, "Vision issuance unavailable") from None
            self._install_vision_issue(op, lease, receipt, digest)
            return response

    def _lease_response(self, lease):
        return dict(leaseId=lease.lease_id, ownerUid=lease.owner_uid,
                    createdAt=lease.created_at, expiresAt=lease.expires_at, status=lease.status, version=lease.version)

    def current_vision_lease(self):
        with self._lock:
            return self._lease_response(self._owned_lease())

    def renew_vision_lease(self):
        # Reauthentication plus proof of the currently active lease; no revival.
        with self._lock:
            lease = self._owned_lease()
            lease.expires_at = datetime.now(timezone.utc) + timedelta(seconds=900)
            lease.deadline = self._lease_clock() + 900
            return self._lease_response(lease)

    def revoke_vision_lease(self):
        with self._lock:
            principal = self._lease_principal()
            lease = self._vision_leases.get(principal.uid)
            if (lease is None or lease.lease_id != principal.vision_lease
                    or lease.auth_time != principal.auth_time):
                raise auth_error(403, "Vision lease access denied")
            # An identical delayed logout never touches a replacement lease.
            if lease.status == "active":
                self._invalidate_lease(lease, "revoked")
                # One explicit logout fences every previously prepared ticket.
                for (uid, _), op in self._vision_operations.items():
                    if uid == principal.uid and op.status == "prepared":
                        op.status = "revoked"
                self._vision_start_versions[principal.uid] = self._vision_start_versions.get(principal.uid, 0) + 1

    def validate_vision_lease(self, record, *, retire_expired=True):
        # Caller holds the session lock through ledger commit/projection.
        return self._active_lease(record.owner_uid, record.vision_lease_id, retire_expired=retire_expired)

    def _persist(self, record: V3SessionRecord) -> None:
        # Imported lazily to avoid any import-time Firebase side effects.
        from app.services.firebase_client import get_firebase_client

        client = get_firebase_client()
        snapshot = record.to_response().model_dump(mode="json", by_alias=True)
        client.set(f"v3GuidanceSessions/{record.session_id}", snapshot)

    def _check_owner(self, record: V3SessionRecord) -> None:
        principal = require_role("passenger")
        if principal.role != "admin" and record.owner_uid != principal.uid:
            raise auth_error(403, "Session access denied")
        if record.vision_lease_id is not None and principal.role != "admin":
            lease = self._owned_lease()
            if record.vision_lease_id != lease.lease_id:
                raise auth_error(403, "Session lease access denied")

    def create(self, *, session_id: str | None = None, wake_word: str = "자비스") -> V3SessionRecord:
        principal = require_role("passenger")
        if principal.role != "admin" and session_id is not None:
            raise auth_error(403, "Create a session without a client-supplied ID")
        with self._lock:
            sid = session_id or new_session_id()
            existing = self._sessions.get(sid)
            if existing:
                self._check_owner(existing)
            lease_id = (self._owned_lease().lease_id if principal.vision_lease else None)
            record = V3SessionRecord(
                vision_lease_id=lease_id, session_id=sid, owner_uid=existing.owner_uid if existing else principal.uid,
                wake_word=wake_word, on_touch=self._persist,
            )
            record.touch()
            self._sessions[sid] = record
            return record

    def get(self, session_id: str = "demo-session", *, wake_word: str = "자비스") -> V3SessionRecord:
        principal = require_role("passenger")
        with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                if principal.role != "admin":
                    raise auth_error(404, "Create a new guidance session first")
                return self.create(session_id=session_id, wake_word=wake_word)
            self._check_owner(record)
            return record

    def reset(self, session_id: str = "demo-session") -> V3SessionRecord:
        with self._lock:
            old = self.get(session_id)
            record = V3SessionRecord(session_id=session_id, owner_uid=old.owner_uid,
                                     wake_word=old.wake_word, vision_lease_id=old.vision_lease_id, on_touch=self._persist)
            record.touch()
            self._sessions[session_id] = record
            return record

    @contextmanager
    def observation_scope(self, session_id: str, *, require_lease=False):
        """Owned, active read scope. Never creates an unknown session."""
        with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                raise auth_error(403, "Observation session access denied")
            self._check_owner(record)
            if record.vision_closed or record.state == GuidanceState.BOARDED:
                raise auth_error(403, "Observation session is not active")
            if require_lease:
                self.validate_vision_lease(record)
            yield record

    @contextmanager
    def vision_scope(self, session_id: str, *, require_lease=False):
        """Internal producer/admin lookup without creating or transferring sessions."""
        require_role("vision_producer", "admin")
        with self._lock:
            record = self._sessions.get(session_id)
            if record is None or record.owner_uid is None or record.vision_closed:
                raise auth_error(403, "Vision session is not active")
            if record.state == GuidanceState.BOARDED:
                raise auth_error(403, "Boarding session has ended")
            if require_lease:
                self.validate_vision_lease(record)
            yield record

    def attach_vision_lease(self, session_id: str) -> None:
        """Enable own-phone preview on an already owned Guidance session.

        Does not reset route state, generation, or another login's lease.
        """
        with self._lock:
            record = self.get(session_id)
            lease = self._owned_lease()
            if record.vision_closed or record.state == GuidanceState.BOARDED:
                raise auth_error(403, "Observation session is not active")
            if record.vision_lease_id not in (None, lease.lease_id):
                raise auth_error(403, "Session lease access denied")
            record.vision_lease_id = lease.lease_id

    def close_vision(self, session_id: str) -> None:
        """Invalidate bindings on explicit session end, without altering guidance."""
        with self._lock:
            record = self.get(session_id)
            record.vision_closed = True
            record.vision_generation = str(uuid4())

    def clear(self) -> None:
        with self._lock:
            self._sessions.clear()
            self._vision_leases.clear()
            self._vision_login_watermark.clear()
            self._vision_operations.clear()
            self._vision_start_versions.clear()
            self._vision_ticket_secret = token_bytes(32)
            self._vision_authority_epoch = token_urlsafe(16)


v3_guidance_store = V3GuidanceStore()
