from fastapi import APIRouter

from app.schemas.ride_request import DriverRideRequestsResponse, RideRequestRecord, RideRequestStatusUpdate
from app.services.ride_request_service import RideRequestService

router = APIRouter()
alias_router = APIRouter()
_service = RideRequestService()


@router.get("/{driverId}/ride-requests", response_model=DriverRideRequestsResponse)
def list_driver_ride_requests(driverId: str) -> DriverRideRequestsResponse:
    """기사별 탑승 요청 목록 조회 인터페이스.

    OpenAPI path parameter 이름은 docs/rw/API_CONTRACTS.md와 동일하게 camelCase(`driverId`)로 고정한다.
    실제 Firebase query 및 driverId 인덱싱은 심현석 담당 구현 섹션에서 완성한다.
    현재는 API 계약과 Flutter 기사용 앱 연동 기준을 고정하기 위한 skeleton이다.
    """
    return _service.list_by_driver(driverId)


@alias_router.get("/ride-requests", response_model=DriverRideRequestsResponse)
def list_current_driver_ride_requests(driverId: str) -> DriverRideRequestsResponse:
    """Driver app alias for querying requests by driverId query parameter."""
    return _service.list_by_driver(driverId)


@alias_router.patch("/ride-requests/{requestId}/status", response_model=RideRequestRecord)
def update_driver_ride_request_status(requestId: str, payload: RideRequestStatusUpdate) -> RideRequestRecord:
    """Driver app alias for status transitions on an assigned ride request."""
    return _service.update_status(requestId, payload.status)
