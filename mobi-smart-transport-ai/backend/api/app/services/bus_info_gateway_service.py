from datetime import datetime, timezone

from app.schemas.bus_info import BusArrival, BusArrivalsResponse, CongestionLevel


class BusInfoGatewayService:
    """김도성의 public_data 서비스와 백엔드 사이의 경계 인터페이스.

    이 클래스는 공공데이터 API 직접 호출을 구현하지 않는다.
    TODO(심현석/김도성 협의): services/public_data 표준 출력과 HTTP/패키지 경계 확정.
    """

    def get_arrivals(self, stop_id: str) -> BusArrivalsResponse:
        return BusArrivalsResponse(
            stopId=stop_id,
            arrivals=[
                BusArrival(
                    routeId="MOCK-502",
                    busNo="502",
                    arrivalMinutes=3,
                    remainingStops=2,
                    lowFloor=True,
                    congestion=CongestionLevel.UNKNOWN,
                    updatedAt=datetime.now(timezone.utc),
                )
            ],
        )
