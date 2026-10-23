"""V3 Beacon Ingest 라우터.

Issue #35 — Backend Beacon Ingest + VM 배포 문서

3개 endpoint:
- POST /api/v3/beacon/ingest: 단일 RSSI 이벤트 수신 + 판정 반환
- GET /api/v3/beacon/latest: 최신 상태 조회 (lost timeout 자동 체크)
- POST /api/v3/beacon/reset: 세션 초기화 (데모용)

기존 v3_beacon.py(/beacon/decision)와 v3_mock.py(/mock/beacons)는
그대로 유지하며, 본 라우터는 별도 prefix(/api/v3/beacon)로 등록한다.

호출자:
- Android BLE bridge (실제 비컨 스캐너)
- 수동 curl (개발/검증용)
- PWA polling (latest 상태 조회)
"""
from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query

from app.schemas.v3 import BeaconIngestRequest, BeaconIngestResponse
from app.services import v3_beacon_service

router = APIRouter()


@router.post("/ingest", response_model=BeaconIngestResponse)
def ingest_beacon(payload: BeaconIngestRequest) -> BeaconIngestResponse:
    """비컨 RSSI 이벤트 수신 + 판정 반환.
    
    Android BLE bridge, 수동 curl, 실제 BLE scanner가 호출한다.
    단일 이벤트를 받아 proximity/decision/phase/cueType/scriptLineId를
    결정하고 _latest_state[sessionId]를 갱신한다.
    
    Threshold는 환경변수로 조정 가능:
    - BEACON_RSSI_NEAR (default -62)
    - BEACON_RSSI_MID (default -75)
    - BEACON_UNSTABLE_DELTA (default 20)
    """
    return v3_beacon_service.evaluate_beacon(payload)


@router.get("/latest", response_model=BeaconIngestResponse)
def get_latest_beacon(
    sessionId: str = Query(default="demo-session", min_length=1)
) -> BeaconIngestResponse:
    """가장 최근 비컨 판정 상태 조회.
    
    PWA polling 또는 Mock UI가 호출한다.
    BEACON_LOST_TIMEOUT(default 5초) 이상 신호 없으면 자동으로
    BEACON_LOST 상태로 전환한다.
    
    Raises:
        404: 해당 세션의 상태가 없음 (ingest 호출 전이거나 reset 후)
    """
    result = v3_beacon_service.get_latest_state(sessionId)
    
    if result is None:
        raise HTTPException(
            status_code=404,
            detail=f"No beacon state for session '{sessionId}'. Call /ingest first."
        )
    
    return result


@router.post("/reset")
def reset_beacon_session(
    sessionId: str = Query(default="demo-session", min_length=1)
) -> dict[str, str]:
    """세션 초기화 (데모용).
    
    _latest_state[sessionId]와 _rssi_history[sessionId]를 모두 제거한다.
    데모 시작 전 깨끗한 상태로 시작하고 싶을 때 호출.
    """
    v3_beacon_service.reset_session(sessionId)
    return {
        "sessionId": sessionId,
        "status": "reset",
    }