from fastapi import APIRouter

from app.schemas.notification import NotificationRequest, NotificationResponse
from app.services.fcm_service import FcmService

router = APIRouter()
_service = FcmService()


@router.post("/send", response_model=NotificationResponse)
def send_notification(payload: NotificationRequest) -> NotificationResponse:
    """Send a one-target FCM notification.

    Target token lookup follows `/fcmTokens/{ownerType}/{ownerId}` only. In
    local/test mode the service returns a mock send result instead of requiring
    Firebase Messaging credentials.
    """
    return _service.send(payload)
