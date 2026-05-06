from fastapi import APIRouter

from app.schemas.bus_info import BusArrivalsResponse
from app.services.bus_info_gateway_service import BusInfoGatewayService

router = APIRouter()
_service = BusInfoGatewayService()


@router.get("/stops/{stopId}/arrivals", response_model=BusArrivalsResponse)
def get_arrivals(stopId: str) -> BusArrivalsResponse:
    """김도성 담당 public_data 서비스의 표준 응답을 백엔드가 받아 전달하는 게이트웨이.

    OpenAPI path parameter 이름은 docs/rw/API_CONTRACTS.md와 동일하게 camelCase(`stopId`)로 고정한다.
    이 라우트는 공공데이터 API를 직접 구현하지 않는다.
    추후 services/public_data가 HTTP 서비스 또는 패키지로 확정되면 연결한다.
    """
    return _service.get_arrivals(stopId)
