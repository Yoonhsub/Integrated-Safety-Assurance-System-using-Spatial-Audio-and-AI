from fastapi import APIRouter

from app.schemas.ride_request import RideRequestCreate, RideRequestRecord, RideRequestStatusUpdate
from app.services.ride_request_service import RideRequestService

router = APIRouter()
_service = RideRequestService()


@router.post("", response_model=RideRequestRecord)
def create_ride_request(payload: RideRequestCreate) -> RideRequestRecord:
    return _service.create(payload)


@router.get("/{requestId}", response_model=RideRequestRecord)
def get_ride_request(requestId: str) -> RideRequestRecord:
    """docs/rw/API_CONTRACTS.md와 OpenAPI path parameter 이름을 requestId로 통일한다."""
    return _service.get(requestId)


@router.patch("/{requestId}/status", response_model=RideRequestRecord)
def update_ride_request_status(requestId: str, payload: RideRequestStatusUpdate) -> RideRequestRecord:
    """docs/rw/API_CONTRACTS.md와 OpenAPI path parameter 이름을 requestId로 통일한다."""
    return _service.update_status(requestId, payload.status)
