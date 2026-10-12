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
import time
from threading import RLock
from datetime import datetime, timezone
from typing import Optional

from app.schemas.v3 import (
    BeaconDecision,
    BeaconIngestRequest,
    BeaconIngestResponse,
    BeaconProximity,
    BeaconSource,
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
_rssi_history: dict[tuple[str, str, str], list[tuple[datetime, int]]] = {}
_observations: dict[str, tuple[datetime, float]] = {}
_state_lock = RLock()


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


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


def _demo_identity(req: BeaconIngestRequest) -> bool | None:
    """Only explicit synthetic fixtures have a known identity here.

    No verified beacon-to-vehicle registry exists. Client busId/routeNo/MAC
    are assertions, not evidence; REAL_BLE must remain unidentified.
    """
    if os.getenv("USE_MOCK_DATA", "false").lower() != "true":
        return None
    if os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off"):
        return None
    if req.source not in (BeaconSource.MANUAL_TEST, BeaconSource.MOCK_BRIDGE):
        return None
    fixtures = {
        "MOBI_BUS_502_TARGET": (True, "BUS_502_NOW", "502"),
        "MOBI_BUS_100_WRONG": (False, "BUS_100", "100"),
    }
    entry = fixtures.get(req.beaconId)
    if entry is None:
        return None
    target, bus_id, route = entry
    if (req.busId is not None and req.busId != bus_id) or (
        req.routeNo is not None and req.routeNo != route
    ):
        return None
    return target


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
        # Unstable observations revoke any previous boarding confirmation.
        return (
            GuidanceState.WAITING_FOR_BUS,
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

def _hold(req: BeaconIngestRequest, warning: str, *, lost: bool = False) -> BeaconIngestResponse:
    return BeaconIngestResponse(
        sessionId=req.sessionId, lastUpdatedAt=req.timestamp,
        beaconId=req.beaconId, routeNo=None, rssi=None, distanceMeters=None,
        proximity=BeaconProximity.LOST if lost else BeaconProximity.UNSTABLE,
        decision=BeaconDecision.BEACON_LOST if lost else BeaconDecision.NO_BEACON,
        phase=GuidanceState.WAITING_FOR_BUS, cueType=CueType.NONE,
        scriptLineId="signal_lost", confidence=0.0, warnings=[warning],
    )


def evaluate_beacon(req: BeaconIngestRequest) -> BeaconIngestResponse:
    """Atomic freshness/order checks and state update within this process.

    timestamp is an untrusted client callback wall-clock time. The server also
    bounds lifetime with a monotonic deadline; HTTP retries never refresh it.
    Only fresh, strictly newer observations may replace an accepted state.
    """
    with _state_lock:
        now = _utc_now()
        stamp = req.timestamp.astimezone(timezone.utc)
        req = req.model_copy(update={"timestamp": stamp})
        age = (now - stamp).total_seconds()
        previous = _observations.get(req.sessionId)
        reason = None
        if age < 0:
            reason = "FUTURE_OBSERVATION: client clock is ahead; observation ignored"
        elif age >= LOST_TIMEOUT_SEC:
            reason = "STALE_OBSERVATION: observation ignored"
        elif previous is not None and stamp <= previous[0]:
            reason = "DUPLICATE_OR_OUT_OF_ORDER: observation ignored"
        if reason:
            current = get_latest_state(req.sessionId)
            if current is not None:
                return current.model_copy(update={"warnings": [*current.warnings, reason]})
            # Rejected input must not create a state or advance a watermark.
            return _hold(req, reason, lost=age >= LOST_TIMEOUT_SEC)

        identity = _demo_identity(req)
        key = (req.sessionId, req.deviceId, req.beaconId)
        history = _rssi_history.get(key, [])
        unstable = bool(history and 0 < (stamp - history[-1][0]).total_seconds() < LOST_TIMEOUT_SEC
                        and abs(req.rssi - history[-1][1]) >= UNSTABLE_DELTA)
        proximity = _classify_proximity(req.rssi, req.distanceMeters)
        if identity is None:
            result = _hold(req, "UNVERIFIED_IDENTITY: no trusted vehicle mapping; boarding withheld")
            # Radio proximity can be measured without knowing the vehicle.
            result = result.model_copy(update={
                "rssi": req.rssi, "distanceMeters": req.distanceMeters,
                "proximity": BeaconProximity.UNSTABLE if unstable else proximity,
            })
        else:
            if unstable:
                decision = BeaconDecision.SIGNAL_UNSTABLE
                proximity = BeaconProximity.UNSTABLE
            elif identity:
                decision = {
                    BeaconProximity.NEAR: BeaconDecision.TARGET_BUS_NEAR,
                    BeaconProximity.MID: BeaconDecision.TARGET_BUS_MID,
                    BeaconProximity.FAR: BeaconDecision.TARGET_BUS_FAR,
                }[proximity]
            else:
                decision = (BeaconDecision.WRONG_BUS_NEAR if proximity in
                            (BeaconProximity.NEAR, BeaconProximity.MID) else BeaconDecision.NO_BEACON)
            phase, cue, script, confidence = _map_decision_to_phase_cue(decision, req.sessionId)
            result = BeaconIngestResponse(
                sessionId=req.sessionId, lastUpdatedAt=stamp, beaconId=req.beaconId,
                routeNo=req.routeNo, rssi=req.rssi, distanceMeters=req.distanceMeters,
                proximity=proximity, decision=decision, phase=phase, cueType=cue,
                scriptLineId=script, confidence=confidence,
                warnings=["SYNTHETIC_DEMO_IDENTITY: not verified vehicle evidence"],
            )
        _latest_state[req.sessionId] = result
        _observations[req.sessionId] = (stamp, time.monotonic() + LOST_TIMEOUT_SEC - age)
        _rssi_history[key] = [*history[-9:], (stamp, req.rssi)]
        return result


def get_latest_state(session_id: str) -> Optional[BeaconIngestResponse]:
    with _state_lock:
        prev = _latest_state.get(session_id)
        observation = _observations.get(session_id)
        if prev is None:
            return None
        if prev.decision == BeaconDecision.BEACON_LOST:
            return prev
        now = _utc_now()
        expired = observation is None or time.monotonic() >= observation[1]
        if observation is not None:
            age = (now - observation[0]).total_seconds()
            expired = expired or age < 0 or age >= LOST_TIMEOUT_SEC
        if expired:
            lost = prev.model_copy(update={
                # Preserve observation time: a poll is not a new detection.
                "rssi": None, "distanceMeters": None,
                "proximity": BeaconProximity.LOST, "decision": BeaconDecision.BEACON_LOST,
                "phase": GuidanceState.WAITING_FOR_BUS, "cueType": CueType.NONE,
                "scriptLineId": "signal_lost", "confidence": 0.0,
                "warnings": ["Observation expired or clock discontinuity; boarding withheld"],
            })
            _latest_state[session_id] = lost
            return lost
        return prev


def reset_session(session_id: str) -> None:
    with _state_lock:
        _latest_state.pop(session_id, None)
        _observations.pop(session_id, None)
        for key in list(_rssi_history):
            if key[0] == session_id:
                del _rssi_history[key]


def get_active_sessions() -> list[str]:
    with _state_lock:
        return list(_latest_state)
