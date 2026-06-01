import logging
from datetime import datetime, timezone

import httpx

from .data_go_kr_client import DataGoKrClient
from .schemas import NormalizedBusLocation, NormalizedBusLocationResponse

logger = logging.getLogger(__name__)

class BusLocationService(DataGoKrClient):
    """국토교통부_(TAGO)_버스위치정보 API 연동 클라이언트."""

    def __init__(
        self,
        api_key: str | None = None,
        base_url: str = "https://apis.data.go.kr/1613000/BusLcInfoInqireService",
        client: httpx.Client | None = None,
    ):
        super().__init__(api_key=api_key, base_url=base_url)
        if client is not None:
            self.client = client

    def get_locations(self, cityCode: str, routeId: str) -> NormalizedBusLocationResponse:
        """지정된 노선의 운행 중인 버스 위치 목록을 반환합니다."""
        response = self.get(
            path="/getRouteAcctoBusLcList",
            params={
                "cityCode": cityCode,
                "routeId": routeId,
                "_type": "json",
                "numOfRows": 100,
                "pageNo": 1,
            },
        )

        data = response.json()
        now = datetime.now(timezone.utc)
        locations: list[NormalizedBusLocation] = []

        try:
            body = data.get("response", {}).get("body", {})
            items = body.get("items")
            if not items or isinstance(items, str):
                return NormalizedBusLocationResponse(routeId=routeId, locations=[])

            item_list = items.get("item", [])
            if isinstance(item_list, dict):
                item_list = [item_list]

            for item in item_list:
                locations.append(
                    NormalizedBusLocation(
                        routeId=routeId,
                        nodeId=str(item.get("nodeid", "")),
                        nodeNm=str(item.get("nodenm", "")),
                        vehicleno=str(item.get("vehicleno", "")),
                        updatedAt=now,
                    )
                )

        except (KeyError, ValueError, TypeError) as e:
            logger.warning(f"Failed to parse bus locations: {e}")

        return NormalizedBusLocationResponse(routeId=routeId, locations=locations)
