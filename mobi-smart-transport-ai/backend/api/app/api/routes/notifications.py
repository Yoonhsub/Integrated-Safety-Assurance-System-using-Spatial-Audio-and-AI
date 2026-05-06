from fastapi import APIRouter

from app.schemas.notification import NotificationRequest, NotificationResponse
from app.services.fcm_service import FcmService

router = APIRouter()
_service = FcmService()


@router.post("/send", response_model=NotificationResponse)
def send_notification(payload: NotificationRequest) -> NotificationResponse:
    """FCM 알림 전송 인터페이스.

    실제 Firebase credential 및 전송 구현은 심현석 담당 섹션에서 완성한다.
    """
    return _service.send(payload)
