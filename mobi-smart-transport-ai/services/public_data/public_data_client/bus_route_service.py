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
        super().__init__(api_key=api_key, base_url=base_url)
        if client is not None:
            self.client = client

    def resolve_route_id(self, cityCode: str, routeNo: str) -> str | None:
        """노선 번호(예: ``502``)로 TAGO ``routeId``를 조회한다.

        ``getRouteNoList``는 동일 번호의 변형 노선을 여러 건 돌려줄 수 있으므로
        ``routeno``가 정확히 일치하는 첫 항목을 우선 사용하고, 없으면 첫 항목으로 폴백한다.
        조회 실패/빈 응답 시 ``None``을 반환해 호출자가 mock 폴백을 결정하게 한다.
        """
        response = self.get(
            path="/getRouteNoList",
            params={
                "cityCode": cityCode,
                "routeNo": routeNo,
                "_type": "json",
                "numOfRows": 100,
                "pageNo": 1,
            },
        )

        data = response.json()
        body = data.get("response", {}).get("body", {})
        items = body.get("items")
        if not items or isinstance(items, str):
            return None

        item_list = items.get("item", [])
        if isinstance(item_list, dict):
            item_list = [item_list]
        if not item_list:
            return None

        for item in item_list:
            if str(item.get("routeno", "")) == str(routeNo):
                route_id = str(item.get("routeid", ""))
                if route_id:
                    return route_id

        first_route_id = str(item_list[0].get("routeid", ""))
        return first_route_id or None

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
