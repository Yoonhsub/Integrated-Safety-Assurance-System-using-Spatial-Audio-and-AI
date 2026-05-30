from __future__ import annotations

from pydantic import BaseModel


class ConverseRequest(BaseModel):
    sessionId: str = "demo-session-001"
    userId: str | None = None
    utterance: str
    lat: float | None = None
    lng: float | None = None


class ConverseResponse(BaseModel):
    recognizedWakeWord: bool
    intent: str
    slots: dict
    guidanceState: str
    message: str
    shouldSpeak: bool = True
    ttsMode: str = "GEMINI_TTS"
    cue: dict | None = None
    debug: dict | None = None
