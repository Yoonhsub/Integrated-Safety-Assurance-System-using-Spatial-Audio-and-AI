from __future__ import annotations

from fastapi import APIRouter

from app.schemas.v3 import (
    BeaconDecision,
    BeaconDecisionResponse,
    BeaconSignal,
    CueType,
    GuidanceState,
    MockBeaconsRequest,
    MockBusEventRequest,
    MockGeofenceRequest,
    MockGeofenceResponse,
    TtsMode,
    V3Cue,
)
from app.services.v3_guidance_store import v3_guidance_store

router = APIRouter()


@router.post("/geofence", response_model=MockGeofenceResponse)
def mock_geofence(payload: MockGeofenceRequest) -> MockGeofenceResponse:
    session = v3_guidance_store.get(payload.sessionId)
    event = payload.event.strip().upper()

    cue = V3Cue(type=CueType.NONE, ttsMode=TtsMode.NONE)
    message = "정류장 대기 범위 상태를 확인했어요."

    if event == "ARRIVED_AT_STOP":
        session.state = GuidanceState.ARRIVED_AT_STOP
        session.geofence_armed = True
        message = "정류장에 도착했어요. 이제 대기 범위 이탈 감지를 시작할게요."
    elif event == "LEFT_WAITING_AREA":
        if session.geofence_armed:
            cue = V3Cue(
                type=CueType.GEOFENCE_WARNING,
                ttsMode=TtsMode.SAFETY_LOCAL,
                shouldVibrate=True,
                message="정류장 대기 범위를 벗어났어요.",
            )
            message = "정류장 대기 범위를 벗어났어요. 다시 정류장 쪽으로 돌아와 주세요."
        else:
            message = "아직 정류장 도착 전이라 대기 범위 이탈 경고를 내지 않을게."
    elif event == "DANGER_ZONE":
        cue = V3Cue(
            type=CueType.DANGER,
            ttsMode=TtsMode.SAFETY_LOCAL,
            shouldVibrate=True,
            shouldBeep=True,
            message="위험 구역이에요.",
        )
        message = "위험 구역이에요. 즉시 안전한 쪽으로 이동해 주세요."
    elif event == "RETURNED_TO_STOP":
        cue = V3Cue(type=CueType.NONE, ttsMode=TtsMode.LOCAL_TTS, message="정류장 대기 범위로 돌아왔어요.")
        if session.geofence_armed:
            session.state = GuidanceState.WAITING_FOR_BUS
        message = "정류장 대기 범위로 돌아왔어요."
    session.touch()
    return MockGeofenceResponse(
        sessionId=session.session_id,
        state=session.state,
        geofenceArmed=session.geofence_armed,
        cue=cue,
        message=message,
    )


@router.post("/beacons", response_model=BeaconDecisionResponse)
def mock_beacons(payload: MockBeaconsRequest) -> BeaconDecisionResponse:
    session = v3_guidance_store.get(payload.sessionId)
    target_bus_id = payload.targetBusId or session.target_bus_id
    target_route_no = payload.targetRouteNo or session.selected_route_no
    if target_bus_id is not None:
        session.target_bus_id = target_bus_id
    if target_route_no is not None:
        session.selected_route_no = target_route_no

    sorted_beacons = sorted(payload.beacons, key=_beacon_sort_key)
    nearest = sorted_beacons[0] if sorted_beacons else None
    target = _find_target_beacon(sorted_beacons, target_bus_id=target_bus_id, target_route_no=target_route_no)

    decision, cue, message = _decide_beacon(nearest=nearest, target=target)

    if decision == BeaconDecision.TARGET_BUS_NEAR and session.state in {
        GuidanceState.ARRIVED_AT_STOP,
        GuidanceState.WAITING_FOR_BUS,
        GuidanceState.REPLAN_NEXT_BUS,
    }:
        session.state = GuidanceState.BOARDING_CONFIRMATION

    session.last_decision = decision
    session.nearest_beacon = nearest.model_dump(mode="json") if nearest else None
    session.target_bus = target.model_dump(mode="json") if target else None
    session.touch()
    return BeaconDecisionResponse(
        sessionId=session.session_id,
        decision=decision,
        nearestBeacon=nearest,
        targetBus=target,
        cue=cue,
        message=message,
    )


@router.post("/bus-event", response_model=MockGeofenceResponse)
def mock_bus_event(payload: MockBusEventRequest) -> MockGeofenceResponse:
    session = v3_guidance_store.get(payload.sessionId)
    event = payload.event.strip().upper()
    if event == "BUS_PASSED":
        session.state = GuidanceState.MISSED_BUS
        message = "버스를 놓친 상태로 기록했어요. 다음 버스를 다시 안내해 드릴 수 있어요."
    else:
        message = "버스 이벤트를 기록했어요."
    session.touch()
    return MockGeofenceResponse(
        sessionId=session.session_id,
        state=session.state,
        geofenceArmed=session.geofence_armed,
        cue=V3Cue(type=CueType.NONE, ttsMode=TtsMode.LOCAL_TTS),
        message=message,
    )


def _beacon_sort_key(item: BeaconSignal) -> tuple[float, int]:
    distance_key = item.distanceMeters if item.distanceMeters is not None else 9999.0
    # Larger RSSI means stronger signal, so invert it for ascending sort.
    rssi_key = -(item.rssi if item.rssi is not None else -9999)
    return (distance_key, rssi_key)


def _find_target_beacon(
    beacons: list[BeaconSignal],
    *,
    target_bus_id: str | None,
    target_route_no: str | None,
) -> BeaconSignal | None:
    if target_bus_id:
        direct = next((item for item in beacons if item.busId == target_bus_id), None)
        if direct is not None:
            return direct
    if target_route_no:
        return next((item for item in beacons if item.routeNo == target_route_no), None)
    return None


def _decide_beacon(
    *,
    nearest: BeaconSignal | None,
    target: BeaconSignal | None,
) -> tuple[BeaconDecision, V3Cue, str]:
    if nearest is None:
        return (
            BeaconDecision.NO_BEACON,
            V3Cue(type=CueType.NONE, ttsMode=TtsMode.NONE),
            "주변 버스 비컨이 감지되지 않았어요.",
        )
    if target is None:
        if _is_near(nearest):
            return (
                BeaconDecision.WRONG_BUS_NEAR,
                V3Cue(type=CueType.WRONG_BUS_NEAR, ttsMode=TtsMode.SAFETY_LOCAL, shouldVibrate=True, shouldBeep=True),
                "가까이 온 버스는 타야 할 버스로 확인되지 않았어요.",
            )
        return (
            BeaconDecision.NO_BEACON,
            V3Cue(type=CueType.NONE, ttsMode=TtsMode.NONE),
            "타야 할 버스 비컨은 아직 감지되지 않았어요.",
        )
    if nearest.busId != target.busId and _is_near(nearest):
        return (
            BeaconDecision.WRONG_BUS_NEAR,
            V3Cue(type=CueType.WRONG_BUS_NEAR, ttsMode=TtsMode.SAFETY_LOCAL, shouldVibrate=True, shouldBeep=True),
            "가까이 온 버스는 타야 할 버스가 아니에요.",
        )
    if _is_near(target):
        return (
            BeaconDecision.TARGET_BUS_NEAR,
            V3Cue(type=CueType.TARGET_BUS_NEAR, ttsMode=TtsMode.LOCAL_TTS, shouldVibrate=True, shouldBeep=True),
            "타야 할 버스가 가까이 왔어요.",
        )
    if _is_mid(target):
        return (
            BeaconDecision.TARGET_BUS_MID,
            V3Cue(type=CueType.TARGET_BUS_MID, ttsMode=TtsMode.LOCAL_TTS, shouldBeep=True),
            "타야 할 버스가 접근 중이에요.",
        )
    return (
        BeaconDecision.TARGET_BUS_FAR,
        V3Cue(type=CueType.TARGET_BUS_FAR, ttsMode=TtsMode.LOCAL_TTS),
        "타야 할 버스가 아직 멀리 있어요.",
    )


def _is_near(beacon: BeaconSignal) -> bool:
    if beacon.distanceMeters is not None:
        return beacon.distanceMeters <= 3.0
    if beacon.rssi is not None:
        return beacon.rssi >= -62
    return False


def _is_mid(beacon: BeaconSignal) -> bool:
    if beacon.distanceMeters is not None:
        return beacon.distanceMeters <= 10.0
    if beacon.rssi is not None:
        return beacon.rssi >= -75
    return False
