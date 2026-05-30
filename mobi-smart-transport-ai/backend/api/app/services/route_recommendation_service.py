from __future__ import annotations

import json
from pathlib import Path

from fastapi import HTTPException

from app.schemas.route_recommendation import ArrivalInfo, BusArrivalsResponse, RouteRecommendResponse

_FIXTURES_PATH = Path(__file__).parent.parent / "fixtures" / "v3_demo_routes.json"

_MOCK_ARRIVALS: dict[str, list[dict]] = {
    "502": [
        {"routeNo": "502", "arrivalMinutes": 6, "busId": "BUS_2", "source": "MOCK"},
        {"routeNo": "502", "arrivalMinutes": 25, "busId": "BUS_2_NEXT", "source": "MOCK"},
    ],
    "105": [
        {"routeNo": "105", "arrivalMinutes": 10, "busId": "BUS_105_1", "source": "MOCK"},
        {"routeNo": "105", "arrivalMinutes": 32, "busId": "BUS_105_2", "source": "MOCK"},
    ],
    "747": [
        {"routeNo": "747", "arrivalMinutes": 15, "busId": "BUS_747_1", "source": "MOCK"},
        {"routeNo": "747", "arrivalMinutes": 40, "busId": "BUS_747_2", "source": "MOCK"},
    ],
}


def _load_fixtures() -> list[dict]:
    with open(_FIXTURES_PATH, encoding="utf-8") as f:
        return json.load(f)


def recommend_route(destination: str) -> dict:
    fixtures = _load_fixtures()
    dest_lower = destination.strip()
    for entry in fixtures:
        if any(alias in dest_lower or dest_lower in alias for alias in entry["aliases"]):
            return entry
    raise HTTPException(status_code=404, detail=f"'{destination}'에 대한 추천 노선을 찾을 수 없습니다.")


def get_arrivals(stop_id: str, route_no: str) -> BusArrivalsResponse:
    arrivals_data = _MOCK_ARRIVALS.get(route_no, [])
    fallback_source = "MOCK" if arrivals_data else None

    if not arrivals_data:
        return BusArrivalsResponse(
            stopId=stop_id,
            routeNo=route_no,
            arrivals=[],
            message=f"{route_no}번 버스 도착 정보를 가져올 수 없습니다.",
            fallbackSource=fallback_source,
        )

    arrivals = [ArrivalInfo(**a) for a in arrivals_data]
    first = arrivals[0]
    msg = f"{route_no}번 버스는 약 {first.arrivalMinutes}분 뒤 도착 예정입니다."
    if len(arrivals) > 1:
        second = arrivals[1]
        msg += f" 다음 {route_no}번 버스는 약 {second.arrivalMinutes}분 뒤 도착 예정입니다."

    return BusArrivalsResponse(
        stopId=stop_id,
        routeNo=route_no,
        arrivals=arrivals,
        message=msg,
        fallbackSource="MOCK",
    )
