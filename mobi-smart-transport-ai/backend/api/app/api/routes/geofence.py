from fastapi import APIRouter

from app.security import require_role, auth_error
from app.schemas.geofence import GeofenceCheckRequest, GeofenceCheckResponse
from app.services.geofence_service import GeofenceService

router = APIRouter()
_service = GeofenceService()


@router.post("/check", response_model=GeofenceCheckResponse)
def check_geofence(payload: GeofenceCheckRequest) -> GeofenceCheckResponse:
    """사용자 GPS 좌표를 받아 안전/경고/위험 상태를 판별한다."""
    principal = require_role("passenger")
    if principal.role != "admin" and payload.userId != principal.uid:
        raise auth_error(403, "Cannot update another user's location")
    return _service.check(payload)
