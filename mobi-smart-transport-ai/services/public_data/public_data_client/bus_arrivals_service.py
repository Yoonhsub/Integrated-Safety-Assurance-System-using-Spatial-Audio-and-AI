from datetime import datetime, timezone

from public_data_client.schemas import CongestionLevel, NormalizedBusArrival, NormalizedBusArrivalsResponse


class BusArrivalsService:
    """정류장별 도착 정보 표준화 서비스 skeleton.

    TODO(김도성):
    - 공공데이터 API 원본 응답을 NormalizedBusArrivalsResponse로 변환
    - 저상버스 여부 및 혼잡도 normalize
    - mock/real provider 분리
    """

    def get_arrivals(self, stop_id: str) -> NormalizedBusArrivalsResponse:
        return NormalizedBusArrivalsResponse(
            stopId=stop_id,
            arrivals=[
                NormalizedBusArrival(
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
