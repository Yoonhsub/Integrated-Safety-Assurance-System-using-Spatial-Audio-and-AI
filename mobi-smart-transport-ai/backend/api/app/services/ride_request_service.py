from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
from threading import Lock
from typing import Any
from uuid import uuid4

from fastapi import HTTPException

from app.security import Principal, auth_error, require_role, valid_key
from app.schemas.ride_request import DriverRideRequestsResponse, RideRequestCreate, RideRequestRecord, RideRequestStatus
from app.services.fcm_service import FcmService
from app.services.firebase_client import FirebaseClient, get_firebase_client


class RideRequestService:
    """Firebase RTDB-backed ride request matching pipeline.

    Official persistence path is `/rideRequests/{requestId}`. The RTDB key is the
    request id; the stored value intentionally does not duplicate `requestId`.
    API responses add `requestId` back from the key so Flutter clients can use the
    shared `RideRequest` response schema without changing the database contract.
    """

    ROOT_PATH = "/rideRequests"
    ALLOWED_TRANSITIONS: dict[RideRequestStatus, set[RideRequestStatus]] = {
        RideRequestStatus.WAITING: {RideRequestStatus.ACCEPTED, RideRequestStatus.CANCELLED},
        RideRequestStatus.NOTIFIED: {RideRequestStatus.ACCEPTED, RideRequestStatus.CANCELLED},
        RideRequestStatus.ACCEPTED: {RideRequestStatus.ARRIVED, RideRequestStatus.COMPLETED, RideRequestStatus.CANCELLED},
        RideRequestStatus.ARRIVED: {RideRequestStatus.COMPLETED, RideRequestStatus.CANCELLED},
        RideRequestStatus.COMPLETED: set(),
        RideRequestStatus.CANCELLED: set(),
    }

    def __init__(self, firebase_client: FirebaseClient | None = None, fcm_service: FcmService | None = None) -> None:
        self.firebase = firebase_client or get_firebase_client()
        self.fcm = fcm_service or FcmService(self.firebase)
        self._created_at_lock = Lock()
        self._last_created_at: datetime | None = None

    def create(self, payload: RideRequestCreate, idempotency_key: str | None = None) -> RideRequestRecord:
        principal = require_role("passenger")
        from app.cloud_test import requested, validate
        if requested():
            scope = validate()
            if payload.userId not in {scope.uid('passenger-a'), scope.uid('passenger-b')}:
                raise auth_error(403, "Passenger is outside the cloud-test run")
        if principal.role != "admin" and payload.userId != principal.uid:
            raise auth_error(403, "Cannot create a request for another user")
        if idempotency_key is not None:
            return self._create_idempotent(payload, idempotency_key, principal)
        payload = self._resolve_assignment(payload, principal)
        now = self._next_created_at()
        request_id = self._new_request_id()
        status = RideRequestStatus.WAITING

        self._set_record(
            request_id,
            {
                "userId": payload.userId,
                "stopId": payload.stopId,
                "routeId": payload.routeId,
                "busNo": payload.busNo,
                "targetDriverId": payload.targetDriverId,
                "status": status.value,
                "createdAt": self._serialize_datetime(now),
                "updatedAt": None,
            },
        )

        self._send_creation_notification(request_id, payload, principal)
        return self.get(request_id)

    def _resolve_assignment(self, payload: RideRequestCreate, principal: Principal) -> RideRequestCreate:
        from app.cloud_test import requested, validate
        if requested():
            scope = validate()
            if not valid_key(payload.routeId):
                raise auth_error(403, "Invalid cloud-test route")
            run = self.firebase.get(scope.path)
            assignment = run.get('assignments', {}).get(payload.routeId) if isinstance(run, dict) else None
            if (not isinstance(run, dict) or run.get('projectId') != scope.project_id
                    or run.get('runId') != scope.run_id or run.get('state') != 'ready'):
                raise auth_error(503, "Cloud-test dispatch is not ready")
            if (not isinstance(assignment, dict) or assignment.get('simulation') is not True
                    or assignment.get('busNo') != payload.busNo
                    or assignment.get('driverId') not in {scope.uid('driver-502'), scope.uid('driver-105')}
                    or payload.targetDriverId not in (None, assignment.get('driverId'))):
                raise auth_error(403, "Cloud-test route assignment denied")
            profile = self.firebase.get('/drivers/' + assignment['driverId'])
            if (not isinstance(profile, dict) or profile.get('cloudTestRun') != scope.run_id
                    or profile.get('simulation') is not True or profile.get('routeId') != payload.routeId
                    or profile.get('busNo') != payload.busNo):
                raise auth_error(403, "Cloud-test driver profile denied")
            payload = payload.model_copy(update={'targetDriverId': assignment['driverId']})
        # Explicit synthetic dispatch only. Never infer a real vehicle assignment.
        from app.local_emulator import emulator_requested, validate_local_emulators
        if emulator_requested() and not payload.targetDriverId:
            validate_local_emulators()
            assignment = self.firebase.get(f"/localDemoAssignments/{payload.routeId}") if valid_key(payload.routeId) else None
            if not isinstance(assignment, dict) or assignment.get("busNo") != payload.busNo:
                raise HTTPException(409, "No local demo driver assigned to this route")
            payload = payload.model_copy(update={"targetDriverId": assignment.get("driverId")})
            if not valid_key(payload.targetDriverId):
                raise HTTPException(409, "Invalid local demo assignment")
        if payload.targetDriverId:
            if not valid_key(payload.targetDriverId):
                raise auth_error(403, "Invalid driver assignment")
            if principal.role != "admin":
                driver = self.firebase.get(f"/drivers/{payload.targetDriverId}")
                if not isinstance(driver, dict) or driver.get("routeId") != payload.routeId or driver.get("busNo") != payload.busNo:
                    raise auth_error(403, "Driver is not assigned to this route and bus")
        return payload

    def _send_creation_notification(self, request_id: str, payload: RideRequestCreate, principal: Principal) -> bool:
        if payload.targetDriverId:
            notification_result = self.fcm.send_ride_request_notification(
                driver_id=payload.targetDriverId,
                request_id=request_id,
                user_id=payload.userId,
                stop_id=payload.stopId,
                route_id=payload.routeId,
                bus_no=payload.busNo,
            )
            if notification_result.accepted:
                def mark_notified(raw: Any) -> dict[str, Any]:
                    current = self._authorized_record(request_id, raw, principal)
                    # A late notification must not undo acceptance/cancellation or
                    # claim notification of a newly assigned driver. No FCM in CAS.
                    if (current.status != RideRequestStatus.WAITING
                            or current.targetDriverId != payload.targetDriverId):
                        return raw
                    return {**raw, "status": RideRequestStatus.NOTIFIED.value,
                            "updatedAt": self._next_updated_at(current)}

                self.firebase.transaction(self._record_path(request_id), mark_notified)

        return bool(payload.targetDriverId and notification_result.accepted)

    @staticmethod
    def _creation_identity(uid: str, key: str, payload: RideRequestCreate) -> tuple[str, str]:
        if not re.fullmatch(r"[A-Za-z0-9._:-]{16,128}", key):
            raise HTTPException(400, "Idempotency-Key must be 16-128 ASCII letters, digits, ., _, :, or -")
        # JSON arrays avoid ambiguous concatenation; scope uses authenticated UID.
        identity = json.dumps([uid, key], ensure_ascii=True, separators=(",", ":"))
        content = json.dumps(payload.model_dump(mode="json"), sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        return "ride-i-" + hashlib.sha256(identity.encode()).hexdigest(), hashlib.sha256(content.encode()).hexdigest()

    def _check_creation(self, request_id: str, raw: Any, principal: Principal, fingerprint: str) -> None:
        self._authorized_record(request_id, raw, principal)
        metadata = raw.get("_creation", {})
        if metadata.get("uid") != principal.uid or metadata.get("fingerprint") != fingerprint:
            raise HTTPException(409, "IDEMPOTENCY_KEY_CONFLICT: use a new key only for a new action")

    def _create_idempotent(self, payload: RideRequestCreate, key: str, principal: Principal) -> RideRequestRecord:
        request_id, fingerprint = self._creation_identity(principal.uid, key, payload)
        path = self._record_path(request_id)
        existing = self.firebase.get(path)
        if existing is not None:
            self._check_creation(request_id, existing, principal, fingerprint)
        else:
            assigned = self._resolve_assignment(payload, principal)
            candidate = {
                **assigned.model_dump(mode="json"), "status": RideRequestStatus.WAITING.value,
                "createdAt": self._serialize_datetime(self._next_created_at()), "updatedAt": None,
                "_creation": {"version": 1, "uid": principal.uid, "fingerprint": fingerprint,
                              "notification": {"state": "pending" if assigned.targetDriverId else "not_required"}},
            }

            def initialize(raw: Any) -> dict[str, Any]:
                if raw is not None:
                    self._check_creation(request_id, raw, principal, fingerprint)
                    return raw
                return candidate

            # Atomic initialization of the request AND its durable deduplication metadata.
            # A pre-read is only an optimization; it never authorizes an unconditional set.
            self.firebase.transaction(path, initialize)
        self._notify_idempotent(request_id, principal, fingerprint)
        return self.get(request_id)

    def _notify_idempotent(self, request_id: str, principal: Principal, fingerprint: str) -> None:
        claim_id = uuid4().hex

        def claim(raw: Any) -> dict[str, Any]:
            self._check_creation(request_id, raw, principal, fingerprint)
            metadata = raw["_creation"]
            notification = metadata["notification"]
            if notification["state"] != "pending":
                return raw
            state = "claimed" if raw["status"] == RideRequestStatus.WAITING.value else "skipped"
            return {**raw, "_creation": {**metadata, "notification": {
                "state": state, "claimId": claim_id, "attemptedAt": self._serialize_datetime(self._utc_now()),
            }}}

        committed = self.firebase.transaction(self._record_path(request_id), claim)
        notice = committed["_creation"]["notification"]
        if notice.get("claimId") != claim_id or notice["state"] != "claimed":
            return
        record = self._record_from_raw(request_id, committed)
        payload = RideRequestCreate(**record.model_dump(include={"userId", "stopId", "routeId", "busNo", "targetDriverId"}))
        try:
            accepted = self._send_creation_notification(request_id, payload, principal)
            state = "accepted" if accepted else "failed"
        except Exception:
            # Ambiguous send outcome: never resend automatically on a duplicate POST.
            state = "unknown"

        def finish(raw: Any) -> dict[str, Any]:
            self._check_creation(request_id, raw, principal, fingerprint)
            metadata = raw["_creation"]
            notification = metadata["notification"]
            if notification.get("claimId") != claim_id:
                return raw
            return {**raw, "_creation": {**metadata, "notification": {**notification, "state": state}}}

        self.firebase.transaction(self._record_path(request_id), finish)

    def get(self, request_id: str) -> RideRequestRecord:
        principal = require_role("passenger", "driver")
        if not valid_key(request_id):
            raise auth_error(403, "Invalid resource identifier")
        raw = self.firebase.get(self._record_path(request_id))
        return self._authorized_record(request_id, raw, principal)

    def _authorized_record(self, request_id: str, raw: Any, principal: Principal) -> RideRequestRecord:
        if not isinstance(raw, dict):
            raise HTTPException(status_code=404, detail=f"Ride request not found: {request_id}")
        record = self._record_from_raw(request_id, raw)
        from app.cloud_test import requested, validate
        if requested():
            scope = validate()
            if (record.userId not in {scope.uid('passenger-a'), scope.uid('passenger-b')}
                    or record.targetDriverId not in {scope.uid('driver-502'), scope.uid('driver-105')}):
                raise auth_error(403, "Request is outside the cloud-test run")
        if principal.role == "passenger" and record.userId != principal.uid:
            raise auth_error(403, "Request access denied")
        if principal.role == "driver" and record.targetDriverId != principal.driver_id:
            raise auth_error(403, "Request is not assigned to this driver")
        return record

    def update_status(self, request_id: str, status: RideRequestStatus) -> RideRequestRecord:
        principal = require_role("passenger", "driver")
        if not valid_key(request_id):
            raise auth_error(403, "Invalid resource identifier")
        if principal.role == "passenger" and status != RideRequestStatus.CANCELLED:
            raise auth_error(403, "Passengers may only cancel their own requests")

        def transition(raw: Any) -> dict[str, Any]:
            # The SDK may retry: recheck ownership and state on EVERY snapshot.
            current = self._authorized_record(request_id, raw, principal)
            if current.status == status:
                return raw  # Idempotent retry; do not bump updatedAt.
            if status not in self.ALLOWED_TRANSITIONS[current.status]:
                raise HTTPException(
                    status_code=409,
                    detail={
                        "error": {
                            "code": "INVALID_RIDE_REQUEST_STATUS_TRANSITION",
                            "message": "Ride request status transition is not allowed.",
                            "detail": {
                                "requestId": request_id,
                                "currentStatus": current.status.value,
                                "requestedStatus": status.value,
                            },
                        }
                    },
                )
            return {**raw, "status": status.value, "updatedAt": self._next_updated_at(current)}

        committed = self.firebase.transaction(self._record_path(request_id), transition)
        return self._record_from_raw(request_id, committed)

    def _next_updated_at(self, current: RideRequestRecord) -> str:
        previous = current.updatedAt or current.createdAt
        if previous.tzinfo is None:
            previous = previous.replace(tzinfo=timezone.utc)
        return self._serialize_datetime(max(self._utc_now(), previous + timedelta(microseconds=1)))

    def list_by_driver(self, driver_id: str) -> DriverRideRequestsResponse:
        principal = require_role("driver")
        if principal.role != "admin" and driver_id != principal.driver_id:
            raise auth_error(403, "Driver access denied")
        from app.cloud_test import requested, validate
        scope = validate() if requested() else None
        if scope and driver_id not in {scope.uid('driver-502'), scope.uid('driver-105')}:
            raise auth_error(403, "Driver is outside the cloud-test run")
        raw_requests = self.firebase.get(self.ROOT_PATH)
        if not isinstance(raw_requests, dict):
            return DriverRideRequestsResponse(driverId=driver_id, requests=[])

        records: list[RideRequestRecord] = []
        for request_id, value in raw_requests.items():
            if not isinstance(value, dict):
                continue
            if scope and value.get('userId') not in {scope.uid('passenger-a'), scope.uid('passenger-b')}:
                continue
            if value.get("targetDriverId") != driver_id:
                continue
            try:
                records.append(self._record_from_raw(str(request_id), value))
            except ValueError:
                continue

        records.sort(key=lambda item: item.createdAt, reverse=True)
        return DriverRideRequestsResponse(driverId=driver_id, requests=records)

    @classmethod
    def _record_path(cls, request_id: str) -> str:
        return f"{cls.ROOT_PATH}/{request_id}"

    @staticmethod
    def _utc_now() -> datetime:
        return datetime.now(timezone.utc)

    def _next_created_at(self) -> datetime:
        with self._created_at_lock:
            now = self._utc_now()
            if self._last_created_at is not None and now <= self._last_created_at:
                now = self._last_created_at + timedelta(microseconds=1)
            self._last_created_at = now
            return now

    @staticmethod
    def _serialize_datetime(value: datetime) -> str:
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f+00:00")

    @staticmethod
    def _new_request_id() -> str:
        return f"ride-{uuid4().hex}"

    def _set_record(self, request_id: str, value: dict[str, Any]) -> None:
        value_without_request_id = dict(value)
        value_without_request_id.pop("requestId", None)
        self.firebase.set(self._record_path(request_id), value_without_request_id)

    @staticmethod
    def _record_from_raw(request_id: str, raw: dict[str, Any]) -> RideRequestRecord:
        # Internal creation metadata never changes the public strict response schema.
        raw = {key: value for key, value in raw.items() if key not in {"requestId", "_creation"}}
        return RideRequestRecord.model_validate({"requestId": request_id, **raw})
