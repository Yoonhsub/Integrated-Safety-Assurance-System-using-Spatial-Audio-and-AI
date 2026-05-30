from __future__ import annotations

from fastapi import APIRouter

from app.schemas.route_recommendation import BusArrivalsResponse, RouteRecommendRequest, RouteRecommendResponse
from app.schemas.guidance import GuidanceState
from app.services import guidance_session_store as store, route_recommendation_service as rec_svc

router = APIRouter()


@router.post("/route-recommend", response_model=RouteRecommendResponse)
def route_recommend(req: RouteRecommendRequest) -> RouteRecommendResponse:
    entry = rec_svc.recommend_route(req.destination)

    session = store.get_session(req.sessionId)
    if session:
        updated = session.model_copy(update={
            "destination": req.destination,
            "selectedStopId": entry["recommendedStopId"],
            "selectedStopName": entry["recommendedStopName"],
            "selectedRouteNo": entry["routeNo"],
            "selectedRouteId": entry["routeId"],
            "guidanceState": GuidanceState.ROUTE_RECOMMENDED,
        })
        store.save_session(updated)

    return RouteRecommendResponse(
        destination=req.destination,
        selectedStopId=entry["recommendedStopId"],
        selectedStopName=entry["recommendedStopName"],
        selectedRouteNo=entry["routeNo"],
        selectedRouteId=entry["routeId"],
        distanceToStopMeters=entry["distanceToStopMeters"],
        message=entry["message"],
        guidanceState="ROUTE_RECOMMENDED",
    )


@router.get("/arrivals", response_model=BusArrivalsResponse)
def get_arrivals(stopId: str, routeNo: str) -> BusArrivalsResponse:
    return rec_svc.get_arrivals(stopId, routeNo)
