from __future__ import annotations

from fastapi import HTTPException

from app.schemas.guidance import GuidanceState
from app.schemas.v3_geofence import GeofenceCue, V3GeofenceResponse, V3GeofenceStatus
from app.services import guidance_session_store as store


def handle_mock_geofence(session_id: str, mock_status: str) -> V3GeofenceResponse:
    session = store.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail=f"세션을 찾을 수 없습니다: {session_id}")

    if mock_status == "ARRIVED_AT_STOP":
        allowed = {
            GuidanceState.ROUTE_SELECTED,
            GuidanceState.NAVIGATING_TO_STOP,
            GuidanceState.ARRIVED_AT_STOP,
            GuidanceState.WAITING_FOR_BUS,
        }
        if session.guidanceState in allowed or True:
            updated = session.model_copy(update={
                "hasArrivedAtStop": True,
                "geofenceArmed": True,
                "guidanceState": GuidanceState.WAITING_FOR_BUS,
            })
            store.save_session(updated)
        return V3GeofenceResponse(
            geofenceStatus=V3GeofenceStatus.SAFE,
            message="정류장 대기 구역에 도착했습니다. 버스를 기다려 주세요.",
            shouldSpeak=True,
            shouldVibrate=False,
            ttsMode="SAFETY_LOCAL",
            cue=None,
        )

    if mock_status == "LEFT_WAITING_AREA":
        if not session.geofenceArmed:
            return V3GeofenceResponse(
                geofenceStatus=V3GeofenceStatus.SAFE,
                message="",
                shouldSpeak=False,
                shouldVibrate=False,
                ttsMode="SAFETY_LOCAL",
            )
        return V3GeofenceResponse(
            geofenceStatus=V3GeofenceStatus.WARNING,
            message="정류장 대기 범위에서 벗어났습니다. 탑승하실 버스를 놓칠 수 있으니 정류장 쪽으로 돌아와 주세요.",
            shouldSpeak=True,
            shouldVibrate=True,
            ttsMode="SAFETY_LOCAL",
            cue=GeofenceCue(
                type="GEOFENCE_WARNING",
                beepPattern="LOW_ONCE",
                vibrationPattern="SHORT_TWICE",
            ),
        )

    if mock_status == "DANGER_ZONE":
        return V3GeofenceResponse(
            geofenceStatus=V3GeofenceStatus.DANGER,
            message="위험 구역으로 이동 중입니다. 즉시 멈추고 정류장 안쪽으로 돌아가세요.",
            shouldSpeak=True,
            shouldVibrate=True,
            ttsMode="SAFETY_LOCAL",
            cue=GeofenceCue(
                type="DANGER",
                beepPattern="LOW_REPEAT",
                vibrationPattern="LONG_REPEAT",
            ),
        )

    if mock_status == "RETURNED_TO_STOP":
        return V3GeofenceResponse(
            geofenceStatus=V3GeofenceStatus.SAFE,
            message="정류장 대기 구역으로 돌아왔습니다.",
            shouldSpeak=True,
            shouldVibrate=False,
            ttsMode="SAFETY_LOCAL",
        )

    raise HTTPException(status_code=400, detail=f"알 수 없는 mockStatus: {mock_status}")
