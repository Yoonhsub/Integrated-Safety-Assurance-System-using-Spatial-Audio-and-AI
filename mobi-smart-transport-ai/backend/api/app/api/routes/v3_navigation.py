"""실시간 내비게이션 통합 상태 API.

Flutter 추적 패널이 30초마다 한 번 호출해 도착/위치/보행경로/근처정류장/운행상태를
한 번에 받는다. 과호출 방지를 위해 서버측 캐시(기본 15s)를 둔다.
Phase 5 Agent Trace step을 안전 payload(키/정밀좌표/원본응답 제외)로 부착한다.
"""
from __future__ import annotations

from fastapi import APIRouter, Query

from app.schemas.v3_map import LiveStatusResponse
from app.services import live_status_service
from app.services.v3_agent_trace import AgentTraceRecorder

router = APIRouter()


@router.get("/live-status", response_model=LiveStatusResponse)
def live_status(
    routeNo: str = Query(min_length=1),
    boardStopId: str = Query(min_length=1),
    routeId: str | None = Query(default=None),
    alightStopId: str | None = Query(default=None),
    sessionId: str | None = Query(default=None),
    userLat: float | None = Query(default=None, ge=-90, le=90),
    userLng: float | None = Query(default=None, ge=-180, le=180),
    boardLat: float | None = Query(default=None, ge=-90, le=90),
    boardLng: float | None = Query(default=None, ge=-180, le=180),
    alightLat: float | None = Query(default=None, ge=-90, le=90),
    alightLng: float | None = Query(default=None, ge=-180, le=180),
    destLat: float | None = Query(default=None, ge=-90, le=90),
    destLng: float | None = Query(default=None, ge=-180, le=180),
    boardStopName: str | None = Query(default=None),
    alightStopName: str | None = Query(default=None),
    destName: str | None = Query(default=None),
    mode: str | None = Query(default=None),
) -> LiveStatusResponse:
    response = live_status_service.get_live_status(
        session_id=sessionId,
        route_no=routeNo,
        route_id=routeId,
        board_stop_id=boardStopId,
        alight_stop_id=alightStopId,
        user_lat=userLat,
        user_lng=userLng,
        board_lat=boardLat,
        board_lng=boardLng,
        alight_lat=alightLat,
        alight_lng=alightLng,
        dest_lat=destLat,
        dest_lng=destLng,
        board_stop_name=boardStopName,
        alight_stop_name=alightStopName,
        dest_name=destName,
        mode=mode,
    )
    _attach_trace(response)
    return response


def _attach_trace(response: LiveStatusResponse) -> None:
    """안전 payload만 담은 Agent Trace step을 부착한다(키/정밀좌표/원본응답 제외)."""
    trace = AgentTraceRecorder()

    trace.record(
        "NEARBY_STOP_SEARCH",
        "주변 정류장 검색 완료",
        f"근처 정류장 {len(response.nearbyStops)}개를 확인했어요."
        if response.nearbyStops
        else "근처 정류장을 찾지 못했어요.",
        operation="searchNearbyStops",
        safe_payload={"nearbyCount": len(response.nearbyStops)},
    )

    walking = response.walkingRouteToBoardStop
    if walking is not None:
        trace.record(
            "TMAP_WALKING_ROUTE",
            "보행경로 확인 완료",
            "승차 정류장까지 보행경로를 확인했어요."
            if not walking.fallbackUsed
            else "보행경로 대신 직선거리로 안내했어요.",
            provider=walking.provider,
            operation="pedestrianRoute",
            safe_payload={
                "provider": walking.provider,
                "operation": "pedestrianRoute",
                "distanceMeters": round(walking.totalDistanceMeters) if walking.totalDistanceMeters else None,
                "durationSeconds": walking.totalDurationSeconds,
                "fallbackUsed": walking.fallbackUsed,
            },
        )
    else:
        trace.skip(
            "TMAP_WALKING_ROUTE",
            "보행경로 확인",
            "현재 위치나 승차 정류장 좌표가 없어서 보행경로를 생략했어요.",
            provider="TMAP",
            operation="pedestrianRoute",
        )

    first_arrival = min((a.arrivalMinutes for a in response.arrivals), default=None)
    trace.record(
        "TAGO_ARRIVAL_LOOKUP",
        "도착정보 확인 완료",
        "승차 정류장 도착 예정 정보를 확인했어요." if response.arrivals else "확인 가능한 도착정보가 없어요.",
        provider="TAGO",
        operation="getArrivals",
        safe_payload={
            "routeNo": response.routeNo,
            "arrivalCount": len(response.arrivals),
            "firstArrivalMinutes": first_arrival,
            "fallbackSource": response.fallbackSource.value,
        },
    )

    trace.record(
        "TAGO_BUS_LOCATION_LOOKUP",
        "버스 위치 확인 완료",
        f"현재 버스 위치 {len(response.busPositions)}건을 확인했어요."
        if response.busPositions
        else "현재 버스 위치는 아직 조회되지 않았어.",
        provider="TAGO",
        operation="getBusLocations",
        safe_payload={"routeNo": response.routeNo, "locationCount": len(response.busPositions)},
    )

    trace.record(
        "LIVE_STATUS_REFRESH",
        "실시간 상태 갱신 완료",
        "지도 패널에 필요한 실시간 정보를 갱신했어요.",
        operation="liveStatusRefresh",
        safe_payload={
            "nextRefreshSeconds": response.nextRefreshSeconds,
            "congestion": response.congestion,
            "warningCount": len(response.warnings),
        },
    )

    response.trace = trace.to_list()
    response.traceId = trace.trace_id
