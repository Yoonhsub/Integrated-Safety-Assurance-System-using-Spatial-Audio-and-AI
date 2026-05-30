from __future__ import annotations

from fastapi import APIRouter

from app.schemas.beacon import BeaconDecisionResponse, MockBeaconsRequest
from app.services.beacon_decision_service import decide

router = APIRouter()


@router.post("/beacons", response_model=BeaconDecisionResponse)
def mock_beacons(req: MockBeaconsRequest) -> BeaconDecisionResponse:
    return decide(req.sessionId, req.beacons)
