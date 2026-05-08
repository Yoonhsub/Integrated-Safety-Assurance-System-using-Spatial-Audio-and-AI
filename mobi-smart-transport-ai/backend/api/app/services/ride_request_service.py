from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from fastapi import HTTPException

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

    def __init__(self, firebase_client: FirebaseClient | None = None, fcm_service: FcmService | None = None) -> None:
        self.firebase = firebase_client or get_firebase_client()
        self.fcm = fcm_service or FcmService(self.firebase)

    def create(self, payload: RideRequestCreate) -> RideRequestRecord:
        now = self._utc_now()
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
                updated_at = self._utc_now()
                self.firebase.update(
                    self._record_path(request_id),
                    {"status": RideRequestStatus.NOTIFIED.value, "updatedAt": self._serialize_datetime(updated_at)},
                )

        return self.get(request_id)

    def get(self, request_id: str) -> RideRequestRecord:
        raw = self.firebase.get(self._record_path(request_id))
        if not isinstance(raw, dict):
            raise HTTPException(status_code=404, detail=f"Ride request not found: {request_id}")
        return self._record_from_raw(request_id, raw)

    def update_status(self, request_id: str, status: RideRequestStatus) -> RideRequestRecord:
        _ = self.get(request_id)
        updated_at = self._utc_now()
        self.firebase.update(
            self._record_path(request_id),
            {"status": status.value, "updatedAt": self._serialize_datetime(updated_at)},
        )
        return self.get(request_id)

    def list_by_driver(self, driver_id: str) -> DriverRideRequestsResponse:
        raw_requests = self.firebase.get(self.ROOT_PATH)
        if not isinstance(raw_requests, dict):
            return DriverRideRequestsResponse(driverId=driver_id, requests=[])

        records: list[RideRequestRecord] = []
        for request_id, value in raw_requests.items():
            if not isinstance(value, dict):
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
        if "requestId" in raw:
            raw = {key: value for key, value in raw.items() if key != "requestId"}
        return RideRequestRecord.model_validate({"requestId": request_id, **raw})
