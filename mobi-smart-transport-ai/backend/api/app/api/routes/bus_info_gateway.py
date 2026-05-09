from fastapi import APIRouter

from app.schemas.bus_info import BusArrivalsResponse
from app.services.bus_info_gateway_service import BusInfoGatewayService

router = APIRouter()
_service = BusInfoGatewayService()


@router.get("/stops/{stopId}/arrivals", response_model=BusArrivalsResponse)
def get_arrivals(stopId: str) -> BusArrivalsResponse:
    """Return bus arrivals through the public_data gateway boundary.

    OpenAPI path parameter 이름은 shared contract와 맞춰 camelCase(`stopId`)로 고정한다.
    이 라우트는 공공데이터 API를 직접 호출하지 않고, RTDB `/busArrivals/{stopId}` 또는
    김도성 public_data mock JSON을 표준 응답 형태로 전달한다.
    """
    return _service.get_arrivals(stopId)
