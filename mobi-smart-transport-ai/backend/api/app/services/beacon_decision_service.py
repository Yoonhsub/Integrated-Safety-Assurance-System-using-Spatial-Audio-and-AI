from __future__ import annotations

from app.schemas.beacon import BeaconCue, BeaconDecision, BeaconDecisionResponse, BeaconEntry
from app.schemas.guidance import GuidanceState
from app.services import guidance_session_store as store

_LEVEL_ORDER = {"near": 0, "mid": 1, "far": 2}


def _nearest(beacons: list[BeaconEntry]) -> BeaconEntry | None:
    if not beacons:
        return None
    return min(beacons, key=lambda b: (_LEVEL_ORDER.get(b.distanceLevel, 99), b.rssi * -1))


def decide(session_id: str, beacons: list[BeaconEntry]) -> BeaconDecisionResponse:
    session = store.get_session(session_id)
    target_route = session.selectedRouteNo if session else None
    target_bus_id = session.targetBusId if session else None

    if not beacons:
        _update_session(session_id, None, None, None, None, BeaconDecision.NO_BEACON)
        return BeaconDecisionResponse(
            decision=BeaconDecision.NO_BEACON,
            message="주변에 감지된 버스가 없습니다.",
            cue=None,
        )

    nearest = _nearest(beacons)
    target_beacons = [b for b in beacons if b.routeNo == target_route]
    target_bus = _nearest(target_beacons) if target_beacons else None

    nearest_route = nearest.routeNo if nearest else None
    nearest_id = nearest.busId if nearest else None

    if not target_route:
        _update_session(session_id, nearest_id, nearest_route,
                        target_bus.relativePosition if target_bus else None,
                        nearest.relativePosition if nearest else None,
                        BeaconDecision.UNKNOWN)
        return BeaconDecisionResponse(
            decision=BeaconDecision.UNKNOWN,
            message="탑승 노선이 설정되지 않았습니다.",
        )

    if not target_bus:
        decision = BeaconDecision.TARGET_BUS_NOT_FOUND
        _update_session(session_id, nearest_id, nearest_route, None,
                        nearest.relativePosition if nearest else None, decision)
        return BeaconDecisionResponse(
            decision=decision,
            message=f"탑승하실 {target_route}번 버스가 아직 감지되지 않았습니다.",
        )

    # Nearest bus is NOT the target
    if nearest and nearest.routeNo != target_route:
        decision = BeaconDecision.WRONG_BUS_NEAR
        _update_session(session_id, nearest_id, nearest_route,
                        target_bus.relativePosition, nearest.relativePosition, decision)
        _arm_approaching(session_id)
        return BeaconDecisionResponse(
            decision=decision,
            message=(
                f"현재 앞에 있는 버스는 탑승하실 버스가 아닙니다. "
                f"탑승하실 {target_route}번 버스는 {target_bus.relativePosition}쪽에 있습니다. "
                "지금은 탑승하지 말고 잠시 대기하세요."
            ),
            ttsMode="SAFETY_LOCAL",
            cue=BeaconCue(
                type="WRONG_BUS_NEAR",
                beepPattern="LOW_DOUBLE",
                vibrationPattern="LONG_ONCE",
            ),
        )

    # Target is nearest — check distance level
    level = target_bus.distanceLevel
    if level == "near":
        decision = BeaconDecision.TARGET_BUS_NEAR
        _update_session(session_id, nearest_id, nearest_route,
                        target_bus.relativePosition, nearest.relativePosition, decision)
        _arm_approaching(session_id)
        return BeaconDecisionResponse(
            decision=decision,
            message=f"탑승하실 {target_route}번 버스가 가까이 접근했습니다. 탑승 준비를 해주세요.",
            cue=BeaconCue(
                type="TARGET_BUS_NEAR",
                beepPattern="FAST_REPEAT",
                vibrationPattern="STRONG_REPEAT",
            ),
        )
    if level == "mid":
        decision = BeaconDecision.TARGET_BUS_MID
        _update_session(session_id, nearest_id, nearest_route,
                        target_bus.relativePosition, nearest.relativePosition, decision)
        return BeaconDecisionResponse(
            decision=decision,
            message=f"탑승하실 {target_route}번 버스가 접근 중입니다.",
            cue=BeaconCue(
                type="TARGET_BUS_MID",
                beepPattern="MEDIUM_ONCE",
                vibrationPattern="MEDIUM_ONCE",
            ),
        )
    decision = BeaconDecision.TARGET_BUS_FAR
    _update_session(session_id, nearest_id, nearest_route,
                    target_bus.relativePosition, nearest.relativePosition, decision)
    return BeaconDecisionResponse(
        decision=decision,
        message=f"탑승하실 {target_route}번 버스가 멀리 있습니다.",
        cue=BeaconCue(
            type="TARGET_BUS_FAR",
            beepPattern="SLOW_ONCE",
            vibrationPattern="LIGHT_ONCE",
        ),
    )


def _arm_approaching(session_id: str) -> None:
    session = store.get_session(session_id)
    if session and session.guidanceState == GuidanceState.WAITING_FOR_BUS:
        updated = session.model_copy(update={"guidanceState": GuidanceState.BUS_APPROACHING})
        store.save_session(updated)


def _update_session(
    session_id: str,
    nearest_beacon_id: str | None,
    nearest_route_no: str | None,
    target_relative_position: str | None,
    nearest_relative_position: str | None,
    decision: BeaconDecision,
) -> None:
    session = store.get_session(session_id)
    if not session:
        return
    updated = session.model_copy(update={
        "nearestBeaconId": nearest_beacon_id,
        "nearestRouteNo": nearest_route_no,
        "targetRelativePosition": target_relative_position,
        "nearestRelativePosition": nearest_relative_position,
        "lastDecision": decision.value,
    })
    store.save_session(updated)
