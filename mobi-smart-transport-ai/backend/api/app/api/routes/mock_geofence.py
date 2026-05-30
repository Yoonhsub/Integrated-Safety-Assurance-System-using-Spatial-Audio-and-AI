from __future__ import annotations

from fastapi import APIRouter

from app.schemas.v3_geofence import MockGeofenceRequest, V3GeofenceResponse
from app.services.v3_geofence_service import handle_mock_geofence

router = APIRouter()


@router.post("/geofence", response_model=V3GeofenceResponse)
def mock_geofence(req: MockGeofenceRequest) -> V3GeofenceResponse:
    return handle_mock_geofence(req.sessionId, req.mockStatus)
