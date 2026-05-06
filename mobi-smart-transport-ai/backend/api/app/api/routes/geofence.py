from fastapi import APIRouter

from app.schemas.geofence import GeofenceCheckRequest, GeofenceCheckResponse
from app.services.geofence_service import GeofenceService

router = APIRouter()
_service = GeofenceService()


@router.post("/check", response_model=GeofenceCheckResponse)
def check_geofence(payload: GeofenceCheckRequest) -> GeofenceCheckResponse:
    """사용자 GPS 좌표를 받아 안전/경고/위험 상태를 판별한다.

    4월 스캐폴딩에서는 알고리즘 프레임만 제공한다.
    실제 polygon 판별 및 상태 전이 로직은 심현석 담당 구현 섹션에서 완성한다.
    """
    return _service.check(payload)
