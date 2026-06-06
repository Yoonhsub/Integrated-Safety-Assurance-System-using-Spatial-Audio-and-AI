"""V3 Beacon Ingest 서비스.

Issue #35 — Backend Beacon Ingest + VM 배포 문서

문서 §5 RSSI 판정 규칙을 구현한다:
- TARGET_BUS_FAR/MID/NEAR
- WRONG_BUS_NEAR
- BEACON_LOST (일정 시간 미감지)
- SIGNAL_UNSTABLE (짧은 시간 RSSI 급변)

기존 v3_mock.py의 _is_near, _is_mid, _decide_beacon 로직을 참고하되,
단일 이벤트 ingest + 최신 상태 저장 + lost timeout 자동 체크를
지원하도록 확장한다.

Threshold는 환경변수로 조정 가능하며, #36 @ajh1206 캘리브레이션 결과로
최종 조정 예정.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Optional

from app.schemas.v3 import (
    BeaconDecision,
    BeaconIngestRequest,
    BeaconIngestResponse,
    BeaconProximity,
    CueType,
    GuidanceState,
)


# ---------------------------------------------------------------------------
# Threshold 환경변수 (캘리브레이션 후 조정)
# ---------------------------------------------------------------------------

RSSI_NEAR_THRESHOLD = int(os.getenv("BEACON_RSSI_NEAR", "-62"))
RSSI_MID_THRESHOLD = int(os.getenv("BEACON_RSSI_MID", "-75"))
LOST_TIMEOUT_SEC = int(os.getenv("BEACON_LOST_TIMEOUT", "5"))
UNSTABLE_DELTA = int(os.getenv("BEACON_UNSTABLE_DELTA", "20"))


# ---------------------------------------------------------------------------
# 메모리 저장소 (데모용, 서버 재시작 시 초기화)
# ---------------------------------------------------------------------------

_latest_state: dict[str, BeaconIngestResponse] = {}
_rssi_history: dict[str, list[tuple[datetime, int]]] = {}


# ---------------------------------------------------------------------------
# 판정 헬퍼
# ---------------------------------------------------------------------------

def _classify_proximity(rssi: int, distance_meters: float | None) -> BeaconProximity:
    """RSSI 또는 거리 기반 proximity 분류.
    
    v3_mock.py의 _is_near, _is_mid 로직과 일관.
    """
    # 거리 정보가 있으면 우선 사용
    if distance_meters is not None:
        if distance_meters <= 3.0:
            return BeaconProximity.NEAR
        if distance_meters <= 10.0:
            return BeaconProximity.MID
        return BeaconProximity.FAR
    
    # RSSI 기반 fallback
    if rssi >= RSSI_NEAR_THRESHOLD:
        return BeaconProximity.NEAR
    if rssi >= RSSI_MID_THRESHOLD:
        return BeaconProximity.MID
    return BeaconProximity.FAR


def _is_target_beacon(req: BeaconIngestRequest) -> bool:
    """beaconId가 target인지 판정.
    
    초기 규칙: beaconId 또는 busId에 'TARGET' 포함 시 target.
    실제 운영에서는 세션의 target_bus_id와 매핑 필요 (#35 추후 확장).
    """
    if "TARGET" in req.beaconId.upper():
        return True
    if req.busId and "TARGET" in req.busId.upper():
        return True
    return False


def _detect_unstable(session_id: str, current_rssi: int, current_time: datetime) -> bool:
    """짧은 시간 RSSI 급변 감지.
    
    이전 RSSI 대비 UNSTABLE_DELTA 이상 변화 시 unstable로 판정.
    """
    history = _rssi_history.get(session_id, [])
    if not history:
        return False
    
    # 최근 1개 이벤트와 비교
    _, last_rssi = history[-1]
    delta = abs(current_rssi - last_rssi)
    return delta >= UNSTABLE_DELTA


def _record_rssi_history(session_id: str, timestamp: datetime, rssi: int) -> None:
    """RSSI 히스토리 기록 (unstable 판정용)."""
    history = _rssi_history.setdefault(session_id, [])
    history.append((timestamp, rssi))
    # 최근 10개만 유지 (메모리 관리)
    if len(history) > 10:
        _rssi_history[session_id] = history[-10:]


def _get_previous_phase(session_id: str) -> GuidanceState:
    """이전 phase 가져오기 (없으면 WAITING_FOR_BUS default)."""
    prev = _latest_state.get(session_id)
    return prev.phase if prev else GuidanceState.WAITING_FOR_BUS


# ---------------------------------------------------------------------------
# decision → (phase, cueType, scriptLineId, confidence) 매핑
# ---------------------------------------------------------------------------

def _map_decision_to_phase_cue(
    decision: BeaconDecision,
    session_id: str,
) -> tuple[GuidanceState, CueType, str, float]:
    """문서 §6 Mock scenario state 연결 표 구현.
    
    Returns:
        (phase, cueType, scriptLineId, confidence)
    """
    if decision == BeaconDecision.TARGET_BUS_NEAR:
        return (
            GuidanceState.BOARDING_CONFIRMATION,
            CueType.TARGET_BUS_NEAR,
            "bus_stopped",
            0.9,
        )
    if decision == BeaconDecision.TARGET_BUS_MID:
        return (
            GuidanceState.WAITING_FOR_BUS,
            CueType.TARGET_BUS_MID,
            "bus_approaching",
            0.78,
        )
    if decision == BeaconDecision.TARGET_BUS_FAR:
        return (
            GuidanceState.WAITING_FOR_BUS,
            CueType.TARGET_BUS_FAR,
            "bus_approaching",
            0.6,
        )
    if decision == BeaconDecision.WRONG_BUS_NEAR:
        return (
            GuidanceState.WAITING_FOR_BUS,
            CueType.WRONG_BUS_NEAR,
            "wrong_bus_warning",
            0.85,
        )
    if decision == BeaconDecision.BEACON_LOST:
        return (
            GuidanceState.WAITING_FOR_BUS,
            CueType.NONE,  # #36에서 CueType 추가 시 LOST로 변경 예정
            "signal_lost",
            0.3,
        )
    if decision == BeaconDecision.SIGNAL_UNSTABLE:
        # 기존 phase 유지 (문서 §6)
        return (
            _get_previous_phase(session_id),
            CueType.NONE,
            "signal_lost",
            0.4,
        )
    # NO_BEACON 등 기본값
    return (
        GuidanceState.WAITING_FOR_BUS,
        CueType.NONE,
        "bus_approaching",
        0.5,
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def evaluate_beacon(req: BeaconIngestRequest) -> BeaconIngestResponse:
    """비컨 이벤트를 받아 판정 결과 반환 + 최신 상태 저장.
    
    1. unstable 감지 (이전 RSSI 대비 급변)
    2. proximity 분류 (NEAR/MID/FAR)
    3. target/wrong 판정
    4. decision 결정
    5. phase/cueType/scriptLineId/confidence 매핑
    6. _latest_state 갱신
    """
    
    # 1. unstable 감지
    is_unstable = _detect_unstable(req.sessionId, req.rssi, req.timestamp)
    
    # 2. proximity 분류
    proximity = _classify_proximity(req.rssi, req.distanceMeters)
    
    # 3. target/wrong 판정
    is_target = _is_target_beacon(req)
    
    # 4. decision 결정
    if is_unstable:
        decision = BeaconDecision.SIGNAL_UNSTABLE
        proximity = BeaconProximity.UNSTABLE
    elif is_target:
        if proximity == BeaconProximity.NEAR:
            decision = BeaconDecision.TARGET_BUS_NEAR
        elif proximity == BeaconProximity.MID:
            decision = BeaconDecision.TARGET_BUS_MID
        else:  # FAR
            decision = BeaconDecision.TARGET_BUS_FAR
    else:  # wrong beacon
        if proximity in (BeaconProximity.NEAR, BeaconProximity.MID):
            decision = BeaconDecision.WRONG_BUS_NEAR
        else:
            # wrong far는 무시. 기존 phase 유지하지만 decision은 NO_BEACON으로
            decision = BeaconDecision.NO_BEACON
    
    # 5. phase/cueType/scriptLineId/confidence 매핑
    phase, cue_type, script_line_id, confidence = _map_decision_to_phase_cue(
        decision, req.sessionId
    )
    
    # 6. 응답 객체 생성
    result = BeaconIngestResponse(
        sessionId=req.sessionId,
        lastUpdatedAt=req.timestamp,
        beaconId=req.beaconId,
        routeNo=req.routeNo,
        rssi=req.rssi,
        distanceMeters=req.distanceMeters,
        proximity=proximity,
        decision=decision,
        phase=phase,
        cueType=cue_type,
        scriptLineId=script_line_id,
        confidence=confidence,
        warnings=[],
    )
    
    # 7. 저장 + 히스토리 기록
    _latest_state[req.sessionId] = result
    _record_rssi_history(req.sessionId, req.timestamp, req.rssi)
    
    return result


def get_latest_state(session_id: str) -> Optional[BeaconIngestResponse]:
    """최신 상태 조회 + lost timeout 자동 체크.
    
    LOST_TIMEOUT_SEC 이상 신호 없으면 BEACON_LOST로 자동 전환.
    """
    prev = _latest_state.get(session_id)
    if not prev:
        return None
    
    # 이미 LOST 상태면 그대로 반환
    if prev.decision == BeaconDecision.BEACON_LOST:
        return prev
    
    # lost timeout 체크
    now = datetime.now(timezone.utc)
    elapsed = (now - prev.lastUpdatedAt).total_seconds()
    
    if elapsed > LOST_TIMEOUT_SEC:
        # LOST로 자동 전환
        phase, cue_type, script_line_id, confidence = _map_decision_to_phase_cue(
            BeaconDecision.BEACON_LOST, session_id
        )
        lost_state = BeaconIngestResponse(
            sessionId=session_id,
            lastUpdatedAt=now,
            beaconId=prev.beaconId,
            routeNo=prev.routeNo,
            rssi=None,
            distanceMeters=None,
            proximity=BeaconProximity.LOST,
            decision=BeaconDecision.BEACON_LOST,
            phase=phase,
            cueType=cue_type,
            scriptLineId=script_line_id,
            confidence=confidence,
            warnings=[f"No beacon signal for over {LOST_TIMEOUT_SEC} seconds"],
        )
        _latest_state[session_id] = lost_state
        return lost_state
    
    return prev


def reset_session(session_id: str) -> None:
    """세션 초기화 (데모용)."""
    _latest_state.pop(session_id, None)
    _rssi_history.pop(session_id, None)


def get_active_sessions() -> list[str]:
    """현재 활성 세션 목록 (디버깅용)."""
    return list(_latest_state.keys())