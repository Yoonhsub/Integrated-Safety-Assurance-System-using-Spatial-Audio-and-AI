from app.schemas.notification import NotificationRequest, NotificationResponse


class FcmService:
    """FCM 알림 서비스 skeleton.

    TODO(심현석):
    - Firebase Admin SDK 초기화
    - /fcmTokens/users/{userId} 또는 /fcmTokens/drivers/{driverId} 조회
    - 위험 경고/탑승 요청 알림 전송
    """

    def send(self, payload: NotificationRequest) -> NotificationResponse:
        return NotificationResponse(
            accepted=False,
            messageId=None,
            detail="FCM 전송은 아직 구현되지 않았습니다. 심현석 담당 섹션에서 완성해야 합니다.",
        )
