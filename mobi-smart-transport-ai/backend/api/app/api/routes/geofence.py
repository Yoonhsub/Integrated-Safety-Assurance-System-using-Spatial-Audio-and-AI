from fastapi import APIRouter

from app.schemas.geofence import GeofenceCheckRequest, GeofenceCheckResponse
from app.services.geofence_service import GeofenceService

router = APIRouter()
_service = GeofenceService()


@router.post("/check", response_model=GeofenceCheckResponse)
def check_geofence(payload: GeofenceCheckRequest) -> GeofenceCheckResponse:
    """사용자 GPS 좌표를 받아 안전/경고/위험 상태를 판별한다."""
    return _service.check(payload)
