import logging

import httpx

from .data_go_kr_client import DataGoKrClient
from .schemas import NormalizedBusRouteNode, NormalizedBusRouteStopsResponse

logger = logging.getLogger(__name__)

class BusRouteService(DataGoKrClient):
    """국토교통부_(TAGO)_버스노선정보 API 연동 클라이언트."""

    def __init__(
        self,
        api_key: str | None = None,
        base_url: str = "https://apis.data.go.kr/1613000/BusRouteInfoInqireService",
        client: httpx.Client | None = None,
    ):
        super().__init__(api_key=api_key, base_url=base_url, client=client)

    def get_route_stops(self, cityCode: str, routeId: str) -> NormalizedBusRouteStopsResponse:
        """지정된 노선이 경유하는 정류소 목록을 반환합니다."""
        response = self.get(
            path="/getRouteAcctoThrghSttnList",
            params={
                "cityCode": cityCode,
                "routeId": routeId,
                "_type": "json",
                "numOfRows": 200,
                "pageNo": 1,
            },
        )

        data = response.json()
        nodes: list[NormalizedBusRouteNode] = []

        try:
            body = data.get("response", {}).get("body", {})
            items = body.get("items")
            if not items or isinstance(items, str):
                return NormalizedBusRouteStopsResponse(routeId=routeId, nodes=[])

            item_list = items.get("item", [])
            if isinstance(item_list, dict):
                item_list = [item_list]

            for item in item_list:
                nodes.append(
                    NormalizedBusRouteNode(
                        nodeId=str(item.get("nodeid", "")),
                        nodeNm=str(item.get("nodenm", "")),
                        nodeOrd=int(item.get("nodeord", 0)),
                    )
                )

        except (KeyError, ValueError, TypeError) as e:
            logger.warning(f"Failed to parse bus route stops: {e}")

        return NormalizedBusRouteStopsResponse(routeId=routeId, nodes=nodes)
