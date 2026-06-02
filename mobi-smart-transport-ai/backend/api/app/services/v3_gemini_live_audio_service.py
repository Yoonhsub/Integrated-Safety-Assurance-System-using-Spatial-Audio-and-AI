from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass
from urllib.parse import quote

import websockets

_DEFAULT_LIVE_AUDIO_MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"
_DEFAULT_LIVE_AUDIO_VOICE = "Sulafat"
_LIVE_API_ENDPOINT = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)


class GeminiLiveAudioUnavailable(RuntimeError):
    """Raised when Gemini Live API cannot produce an audio stream."""


@dataclass(frozen=True)
class GeminiLiveAudioChunk:
    data: str
    mime_type: str


def live_audio_model() -> str:
    return (
        os.getenv("GEMINI_LIVE_AUDIO_MODEL", _DEFAULT_LIVE_AUDIO_MODEL).strip()
        or _DEFAULT_LIVE_AUDIO_MODEL
    ).removeprefix("models/")


def live_audio_voice() -> str:
    return (
        os.getenv("GEMINI_TTS_VOICE", _DEFAULT_LIVE_AUDIO_VOICE).strip()
        or _DEFAULT_LIVE_AUDIO_VOICE
    )


def live_audio_setup_message(*, model: str, voice: str) -> dict:
    return {
        "setup": {
            "model": f"models/{model.removeprefix('models/')}",
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {
                    "voiceConfig": {
                        "prebuiltVoiceConfig": {
                            "voiceName": voice,
                        }
                    }
                },
            },
            "systemInstruction": {
                "parts": [
                    {
                        "text": (
                            "You are MOBI's Korean transit guidance voice. "
                            "Read the provided Korean transcript warmly, calmly, and clearly. "
                            "Do not add, remove, paraphrase, or answer anything. "
                            "Speak only the provided transcript."
                        )
                    }
                ]
            },
        }
    }


def live_audio_text_message(*, text: str) -> dict:
    return {
        "realtimeInput": {
            "text": f"Speak only this transcript:\n{text.strip()}",
        }
    }


async def stream_live_audio_pcm(*, text: str) -> AsyncIterator[GeminiLiveAudioChunk]:
    api_key = os.getenv("GEMINI_API_KEY", "").strip()
    if not api_key:
        raise GeminiLiveAudioUnavailable("Gemini API key is not configured.")

    endpoint = f"{_LIVE_API_ENDPOINT}?key={quote(api_key)}"
    try:
        async with websockets.connect(
            endpoint,
            open_timeout=5,
            close_timeout=2,
            max_size=4 * 1024 * 1024,
        ) as google_socket:
            await google_socket.send(
                json.dumps(
                    live_audio_setup_message(
                        model=live_audio_model(),
                        voice=live_audio_voice(),
                    ),
                    ensure_ascii=False,
                )
            )
            setup_response = _decode_message(
                await asyncio.wait_for(google_socket.recv(), timeout=5)
            )
            if "setupComplete" not in setup_response:
                raise GeminiLiveAudioUnavailable("Gemini Live API setup failed.")

            await google_socket.send(
                json.dumps(live_audio_text_message(text=text), ensure_ascii=False)
            )

            chunk_count = 0
            while True:
                response = _decode_message(
                    await asyncio.wait_for(google_socket.recv(), timeout=15)
                )
                server_content = response.get("serverContent")
                if not isinstance(server_content, dict):
                    continue

                model_turn = server_content.get("modelTurn")
                parts = model_turn.get("parts") if isinstance(model_turn, dict) else []
                if isinstance(parts, list):
                    for part in parts:
                        if not isinstance(part, dict):
                            continue
                        inline_data = part.get("inlineData")
                        if not isinstance(inline_data, dict):
                            continue
                        data = inline_data.get("data")
                        if not isinstance(data, str) or not data:
                            continue
                        mime_type = inline_data.get("mimeType")
                        chunk_count += 1
                        yield GeminiLiveAudioChunk(
                            data=data,
                            mime_type=(
                                mime_type
                                if isinstance(mime_type, str) and mime_type
                                else "audio/pcm;rate=24000"
                            ),
                        )

                if server_content.get("interrupted"):
                    raise GeminiLiveAudioUnavailable(
                        "Gemini Live API audio generation was interrupted."
                    )
                if server_content.get("generationComplete") or server_content.get(
                    "turnComplete"
                ):
                    break

            if chunk_count == 0:
                raise GeminiLiveAudioUnavailable(
                    "Gemini Live API returned no audio chunks."
                )
    except GeminiLiveAudioUnavailable:
        raise
    except Exception as exc:
        raise GeminiLiveAudioUnavailable(
            "Gemini Live API audio streaming failed."
        ) from exc


def _decode_message(raw: str | bytes) -> dict:
    try:
        decoded = json.loads(raw)
    except (TypeError, json.JSONDecodeError) as exc:
        raise GeminiLiveAudioUnavailable(
            "Gemini Live API returned an invalid message."
        ) from exc
    if not isinstance(decoded, dict):
        raise GeminiLiveAudioUnavailable(
            "Gemini Live API returned an invalid message."
        )
    return decoded
