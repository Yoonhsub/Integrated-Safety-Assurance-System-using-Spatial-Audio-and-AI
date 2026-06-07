from __future__ import annotations

from fastapi import APIRouter

from app.schemas.v3 import BeaconDecision, BeaconDecisionResponse, CueType, TtsMode, V3Cue
from app.services.v3_guidance_store import v3_guidance_store

router = APIRouter()


def _cue_for_decision(decision: BeaconDecision) -> V3Cue:
    if decision == BeaconDecision.WRONG_BUS_NEAR:
        return V3Cue(type=CueType.WRONG_BUS_NEAR, ttsMode=TtsMode.SAFETY_LOCAL, shouldVibrate=True, shouldBeep=True)
    if decision == BeaconDecision.TARGET_BUS_NEAR:
        return V3Cue(type=CueType.TARGET_BUS_NEAR, ttsMode=TtsMode.LOCAL_TTS, shouldVibrate=True, shouldBeep=True)
    if decision == BeaconDecision.TARGET_BUS_MID:
        return V3Cue(type=CueType.TARGET_BUS_MID, ttsMode=TtsMode.LOCAL_TTS, shouldBeep=True)
    if decision == BeaconDecision.TARGET_BUS_FAR:
        return V3Cue(type=CueType.TARGET_BUS_FAR, ttsMode=TtsMode.LOCAL_TTS)
    return V3Cue(type=CueType.NONE, ttsMode=TtsMode.NONE)


@router.get("/decision", response_model=BeaconDecisionResponse)
def get_last_decision(sessionId: str = "demo-session") -> BeaconDecisionResponse:
    session = v3_guidance_store.get(sessionId)
    decision = session.last_decision or BeaconDecision.NO_BEACON
    return BeaconDecisionResponse(
        sessionId=session.session_id,
        decision=decision,
        nearestBeacon=session.nearest_beacon,
        targetBus=session.target_bus,
        cue=_cue_for_decision(decision),
        message="마지막 비컨 판별 결과예요.",
    )
