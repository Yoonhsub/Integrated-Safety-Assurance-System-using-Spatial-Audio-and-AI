import logging
import re

import httpx

from .data_go_kr_client import DataGoKrClient
from .schemas import NormalizedBusRouteNode, NormalizedBusRouteStopsResponse

_ROUTE_NO = re.compile(r"[A-Za-z]?[0-9]{1,4}(?:-[0-9]{1,3}|[A-Za-z])?")
_ROUTE_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")

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
        ``routeno``가 정확히 일치하는 첫 항목을 사용한다.
        """
        route_ids = self.resolve_route_ids(cityCode, routeNo)
        return route_ids[0] if route_ids else None

    def resolve_route_ids(self, cityCode: str, routeNo: str, *, verify_page: bool = False) -> list[str]:
        """Return every TAGO routeId variant for a route number.

        Directional variants can share the same displayed route number. Keeping
        all exact matches lets the route-sequence cache validate direction by
        node order instead of accidentally selecting only the first variant.
        """
        response = self.get(
            path="/getRouteNoList",
            params={
                "cityCode": cityCode,
                "routeNo": routeNo,
                "_type": "json",
                "numOfRows": 10 if verify_page else 100,
                "pageNo": 1,
            },
        )

        data = response.json()
        if verify_page:
            return list({item["routeid"]: None for item in self._verified_items(data)
                         if str(item.get("routeno", "")) == routeNo
                         and isinstance(item.get("routeid"), str) and _ROUTE_ID.fullmatch(item["routeid"])})
        body = data.get("response", {}).get("body", {})
        items = body.get("items")
        if not items or isinstance(items, str):
            return []

        item_list = items.get("item", [])
        if isinstance(item_list, dict):
            item_list = [item_list]
        if not item_list:
            return []

        exact_route_ids: list[str] = []
        for item in item_list:
            if str(item.get("routeno", "")) == str(routeNo):
                route_id = str(item.get("routeid", ""))
                if route_id and route_id not in exact_route_ids:
                    exact_route_ids.append(route_id)
        return exact_route_ids

    def routes_serving_stop(self, city_code: str, stop_id: str) -> dict[str, str]:
        """Verified route ID and display number pairs for one provider stop ID."""
        response = self.get("/getSttnThrghRouteList",
            base_url="https://apis.data.go.kr/1613000/BusSttnInfoInqireService",
            timeout=2.0,
            params={"cityCode": city_code, "nodeid": stop_id, "pageNo": "1", "numOfRows": "100", "_type": "json"})
        routes: dict[str, str] = {}
        for item in self._verified_items(response.json()):
            route_id, number = item.get("routeid"), str(item.get("routeno", ""))
            if not isinstance(route_id, str) or not _ROUTE_ID.fullmatch(route_id) or not _ROUTE_NO.fullmatch(number):
                raise ValueError("Invalid TAGO stop route")
            if routes.setdefault(route_id, number) != number:
                raise ValueError("Conflicting TAGO route numbers")
        return routes

    @staticmethod
    def _verified_items(payload: dict) -> list[dict]:
        response = payload["response"]
        if str(response["header"]["resultCode"]) not in {"0", "00"}:
            raise ValueError("TAGO route lookup rejected")
        body = response["body"]
        items = body.get("items") or {}
        rows = items.get("item", [])
        if isinstance(rows, dict):
            rows = [rows]
        if (not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows)
                or int(body["totalCount"]) != len(rows) or int(body.get("pageNo", 1)) != 1):
            raise ValueError("Incomplete TAGO route list")
        return rows

    def get_route_stops(self, cityCode: str, routeId: str, *, verify_page: bool = False) -> NormalizedBusRouteStopsResponse:
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
        if verify_page:
            rows = self._verified_items(data)
            nodes = [NormalizedBusRouteNode(nodeId=row["nodeid"], nodeNm=row["nodenm"],
                nodeOrd=int(row["nodeord"])) for row in rows]
            if (any(not _ROUTE_ID.fullmatch(node.nodeId) or not node.nodeNm.strip() or node.nodeOrd <= 0 for node in nodes)
                    or len({node.nodeOrd for node in nodes}) != len(nodes)
                    or any(row.get("routeid", routeId) != routeId for row in rows)):
                raise ValueError("Invalid TAGO stop sequence")
            return NormalizedBusRouteStopsResponse(routeId=routeId, nodes=nodes)
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
                        latitude=_float_or_none(
                            item.get("gpslati")
                            or item.get("gpsLat")
                            or item.get("lat")
                            or item.get("latitude")
                        ),
                        longitude=_float_or_none(
                            item.get("gpslong")
                            or item.get("gpsLong")
                            or item.get("lng")
                            or item.get("lon")
                            or item.get("longitude")
                        ),
                    )
                )

        except (KeyError, ValueError, TypeError) as e:
            logger.warning(f"Failed to parse bus route stops: {e}")

        return NormalizedBusRouteStopsResponse(routeId=routeId, nodes=nodes)


def _float_or_none(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None
