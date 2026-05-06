from datetime import datetime, timezone
from uuid import uuid4

from app.schemas.ride_request import DriverRideRequestsResponse, RideRequestCreate, RideRequestRecord, RideRequestStatus


class RideRequestService:
    """기사-승객 매칭 요청 서비스 skeleton.

    TODO(심현석):
    - Firebase /rideRequests 쓰기/읽기/상태 변경
    - FCM 기사 알림 연동
    - driverId별 요청 조회 Firebase 연동
    """

    def create(self, payload: RideRequestCreate) -> RideRequestRecord:
        now = datetime.now(timezone.utc)
        return RideRequestRecord(
            requestId=f"mock-{uuid4()}",
            userId=payload.userId,
            stopId=payload.stopId,
            routeId=payload.routeId,
            busNo=payload.busNo,
            targetDriverId=payload.targetDriverId,
            status=RideRequestStatus.WAITING,
            createdAt=now,
            updatedAt=None,
        )

    def get(self, request_id: str) -> RideRequestRecord:
        now = datetime.now(timezone.utc)
        return RideRequestRecord(
            requestId=request_id,
            userId="mock-user",
            stopId="mock-stop",
            routeId="mock-route",
            busNo="mock-bus",
            targetDriverId=None,
            status=RideRequestStatus.WAITING,
            createdAt=now,
            updatedAt=None,
        )

    def update_status(self, request_id: str, status: RideRequestStatus) -> RideRequestRecord:
        record = self.get(request_id)
        return record.model_copy(update={"status": status, "updatedAt": datetime.now(timezone.utc)})


    def list_by_driver(self, driver_id: str) -> DriverRideRequestsResponse:
        """기사별 탑승 요청 목록 skeleton.

        TODO(심현석): Firebase에서 targetDriverId == driver_id 또는 노선/버스 매칭 기준으로 조회한다.
        """
        now = datetime.now(timezone.utc)
        return DriverRideRequestsResponse(
            driverId=driver_id,
            requests=[
                RideRequestRecord(
                    requestId=f"mock-{uuid4()}",
                    userId="mock-user",
                    stopId="mock-stop",
                    routeId="mock-route",
                    busNo="mock-bus",
                    targetDriverId=driver_id,
                    status=RideRequestStatus.WAITING,
                    createdAt=now,
                    updatedAt=None,
                )
            ],
        )
