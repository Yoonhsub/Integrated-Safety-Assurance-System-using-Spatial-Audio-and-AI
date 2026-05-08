from __future__ import annotations

import os
from datetime import UTC, datetime
from enum import Enum
from typing import Any
from uuid import uuid4

from pydantic import Field

from app.schemas.base import StrictApiModel
from app.schemas.notification import NotificationRequest, NotificationResponse, NotificationType
from app.services.firebase_client import FirebaseClient, get_firebase_client


class FcmOwnerType(str, Enum):
    USER = "users"
    DRIVER = "drivers"


class FcmPlatform(str, Enum):
    ANDROID = "android"
    IOS = "ios"
    WEB = "web"
    UNKNOWN = "unknown"


class FcmTokenRecord(StrictApiModel):
    token: str = Field(min_length=1)
    platform: FcmPlatform = FcmPlatform.UNKNOWN
    updatedAt: str


class FcmTarget(StrictApiModel):
    ownerType: FcmOwnerType
    ownerId: str = Field(min_length=1)


class FcmService:
    """FCM notification service with Firebase RTDB token lookup and mock transport.

    Official token storage path is `/fcmTokens/{ownerType}/{ownerId}`.
    Concrete examples: `/fcmTokens/users/{userId}` and `/fcmTokens/drivers/{driverId}`. The
    Flutter apps own token registration lifecycle, while the backend only reads
    those token records and sends one-target notifications. When FCM credentials
    are unavailable, the service returns deterministic mock-style responses so
    local tests and section work do not depend on secrets.
    """

    def __init__(self, firebase_client: FirebaseClient | None = None) -> None:
        self.firebase = firebase_client or get_firebase_client()

    def save_token(
        self,
        *,
        owner_type: FcmOwnerType | str,
        owner_id: str,
        token: str,
        platform: FcmPlatform | str = FcmPlatform.UNKNOWN,
        updated_at: datetime | None = None,
    ) -> FcmTokenRecord:
        """Store a token at the official RTDB path.

        This method is intentionally service-level. The 4월 MVP contract says
        Flutter clients normally write this path directly after Firebase Auth;
        tests and backend admin workflows can still use this helper without
        creating duplicate `/users/*/fcmToken` or `/drivers/*/fcmToken` fields.
        """
        target_owner_type = FcmOwnerType(owner_type)
        target_platform = FcmPlatform(platform)
        if not owner_id.strip():
            raise ValueError("owner_id must be a non-empty string.")
        if not token.strip():
            raise ValueError("token must be a non-empty string.")

        record = FcmTokenRecord(
            token=token.strip(),
            platform=target_platform,
            updatedAt=(updated_at or datetime.now(UTC)).isoformat(),
        )
        self.firebase.set(self._token_path(target_owner_type, owner_id), record.model_dump(mode="json"))
        return record

    def get_user_token(self, user_id: str) -> FcmTokenRecord | None:
        return self._get_token_record(FcmOwnerType.USER, user_id)

    def get_driver_token(self, driver_id: str) -> FcmTokenRecord | None:
        return self._get_token_record(FcmOwnerType.DRIVER, driver_id)

    def send(self, payload: NotificationRequest) -> NotificationResponse:
        target = self._target_from_payload(payload)
        token_record = self._get_token_record(target.ownerType, target.ownerId)
        if token_record is None:
            return NotificationResponse(
                accepted=False,
                messageId=None,
                detail=f"FCM token not found at {self._token_path(target.ownerType, target.ownerId)}.",
            )

        if self._should_use_mock_transport():
            return NotificationResponse(
                accepted=True,
                messageId=self._mock_message_id(target),
                detail="Mock FCM send accepted. Real Firebase Messaging was not used.",
            )

        return self._send_with_firebase_messaging(payload=payload, token=token_record.token)

    def send_safety_alert(
        self,
        *,
        user_id: str,
        stop_id: str,
        geofence_status: str,
        title: str = "안전 경고",
        body: str | None = None,
    ) -> NotificationResponse:
        return self.send(
            NotificationRequest(
                targetUserId=user_id,
                type=NotificationType.SAFETY_ALERT,
                title=title,
                body=body or "위험 구역에 접근 중입니다. 지정된 안전 위치로 이동해 주세요.",
                data={"stopId": stop_id, "geofenceStatus": geofence_status},
            )
        )

    def send_ride_request_notification(
        self,
        *,
        driver_id: str,
        request_id: str,
        user_id: str,
        stop_id: str,
        route_id: str,
        bus_no: str,
        title: str = "탑승 요청",
    ) -> NotificationResponse:
        return self.send(
            NotificationRequest(
                targetDriverId=driver_id,
                type=NotificationType.RIDE_REQUEST,
                title=title,
                body=f"{bus_no}번 버스 탑승 요청이 도착했습니다.",
                data={
                    "requestId": request_id,
                    "userId": user_id,
                    "stopId": stop_id,
                    "routeId": route_id,
                    "busNo": bus_no,
                },
            )
        )

    @staticmethod
    def _token_path(owner_type: FcmOwnerType, owner_id: str) -> str:
        return f"/fcmTokens/{owner_type.value}/{owner_id}"

    def _get_token_record(self, owner_type: FcmOwnerType, owner_id: str) -> FcmTokenRecord | None:
        if not owner_id.strip():
            return None
        raw = self.firebase.get(self._token_path(owner_type, owner_id))
        if not isinstance(raw, dict):
            return None
        try:
            return FcmTokenRecord.model_validate(raw)
        except ValueError:
            return None

    @staticmethod
    def _target_from_payload(payload: NotificationRequest) -> FcmTarget:
        if payload.targetUserId is not None:
            return FcmTarget(ownerType=FcmOwnerType.USER, ownerId=payload.targetUserId)
        if payload.targetDriverId is not None:
            return FcmTarget(ownerType=FcmOwnerType.DRIVER, ownerId=payload.targetDriverId)
        raise ValueError("NotificationRequest must contain one target.")

    def _should_use_mock_transport(self) -> bool:
        fcm_enabled = os.getenv("FCM_ENABLED", "false").strip().lower() in {"1", "true", "yes", "y", "on"}
        return not fcm_enabled or self.firebase.using_mock

    @staticmethod
    def _mock_message_id(target: FcmTarget) -> str:
        return f"mock-fcm-{target.ownerType.value}-{target.ownerId}-{uuid4().hex[:12]}"

    def _send_with_firebase_messaging(self, *, payload: NotificationRequest, token: str) -> NotificationResponse:
        try:
            if not self.firebase.initialize():
                return NotificationResponse(
                    accepted=True,
                    messageId=self._mock_message_id(self._target_from_payload(payload)),
                    detail="Mock FCM send accepted because Firebase Admin SDK is not initialized.",
                )

            from firebase_admin import messaging

            message = messaging.Message(
                token=token,
                notification=messaging.Notification(title=payload.title, body=payload.body),
                data=dict(payload.data),
            )
            message_id = messaging.send(message)
            return NotificationResponse(accepted=True, messageId=str(message_id), detail="FCM send accepted.")
        except Exception as exc:  # pragma: no cover - depends on Firebase credentials/network
            return NotificationResponse(accepted=False, messageId=None, detail=f"FCM send failed: {exc}")
