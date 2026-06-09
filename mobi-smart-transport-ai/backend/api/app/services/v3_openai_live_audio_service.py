"""OpenAI Realtime 기반 Live 오디오(스트리밍 TTS·실시간 STT).

Gemini Live(`v3_gemini_live_audio_service`)가 크레딧 등으로 막혔을 때 Live 음성 대화 모드를
OpenAI Realtime API로 대체한다. 라우트가 provider로 둘 중 하나를 고른다.

- TTS 스트리밍: `wss://api.openai.com/v1/realtime?model=<realtime>` → response.output_audio.delta
  (base64 pcm16 24kHz)를 GeminiLiveAudioChunk와 동일한 모양으로 yield.
- STT: `wss://...?intent=transcription` → session.update(type=transcription, audio.input.*)
  → input_audio_buffer.append → conversation.item.input_audio_transcription.delta/.completed.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import struct
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

import websockets

_REALTIME_URL = "wss://api.openai.com/v1/realtime"
_DEFAULT_REALTIME_MODEL = "gpt-realtime-2"
_DEFAULT_VOICE = "marin"
_DEFAULT_STT_MODEL = "gpt-4o-mini-transcribe"
# OpenAI 전사 세션은 input format rate >= 24000을 요구한다. 브라우저는 16k로 보내므로
# 백엔드에서 24k로 업샘플해 보낸다(세션은 항상 24000으로 연다).
_STT_SESSION_RATE = 24000
_TTS_SYSTEM = (
    "You are MOBI's Korean transit-guidance voice for a blind passenger. Read the user's text "
    "aloud EXACTLY and verbatim in a warm, friendly, polite Korean (존댓말) voice with natural "
    "human intonation. Do not add, change, translate, summarize, answer, or comment. Speak only "
    "the exact transcript the user gives."
)


class OpenAiLiveAudioUnavailable(RuntimeError):
    """Raised when the OpenAI Realtime API cannot produce audio/transcription."""


@dataclass(frozen=True)
class OpenAiLiveAudioChunk:
    data: str
    mime_type: str


def realtime_model() -> str:
    return (os.getenv("OPENAI_REALTIME_MODEL", _DEFAULT_REALTIME_MODEL).strip()
            or _DEFAULT_REALTIME_MODEL)


def realtime_voice() -> str:
    return (os.getenv("OPENAI_TTS_VOICE", _DEFAULT_VOICE).strip() or _DEFAULT_VOICE)


def stt_model() -> str:
    return (os.getenv("OPENAI_STT_MODEL", _DEFAULT_STT_MODEL).strip() or _DEFAULT_STT_MODEL)


async def _connect(url: str):
    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise OpenAiLiveAudioUnavailable("OPENAI_API_KEY is not configured.")
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        try:
            return await websockets.connect(
                url, additional_headers=headers, max_size=None, open_timeout=6, close_timeout=2
            )
        except TypeError:
            return await websockets.connect(
                url, extra_headers=headers, max_size=None, open_timeout=6, close_timeout=2
            )
    except OpenAiLiveAudioUnavailable:
        raise
    except Exception as exc:  # noqa: BLE001
        raise OpenAiLiveAudioUnavailable("OpenAI Realtime connection failed.") from exc


async def stream_openai_realtime_pcm(*, text: str) -> AsyncIterator[OpenAiLiveAudioChunk]:
    """텍스트를 OpenAI Realtime으로 합성해 pcm16 24kHz 청크를 스트리밍한다."""
    model = realtime_model()
    voice = realtime_voice()
    ws = await _connect(f"{_REALTIME_URL}?model={model}")
    try:
        await asyncio.wait_for(ws.recv(), timeout=6)  # session.created
        await ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "type": "realtime",
                "output_modalities": ["audio"],
                "audio": {"output": {"voice": voice}},
                "instructions": _TTS_SYSTEM,
            },
        }))
        await ws.send(json.dumps({
            "type": "conversation.item.create",
            "item": {"type": "message", "role": "user",
                     "content": [{"type": "input_text", "text": text}]},
        }))
        await ws.send(json.dumps({"type": "response.create"}))
        chunk_count = 0
        while True:
            raw = await asyncio.wait_for(ws.recv(), timeout=20)
            event = json.loads(raw)
            event_type = event.get("type", "")
            if event_type == "response.output_audio.delta":
                delta = event.get("delta")
                if isinstance(delta, str) and delta:
                    chunk_count += 1
                    yield OpenAiLiveAudioChunk(data=delta, mime_type="audio/pcm;rate=24000")
            elif event_type in ("response.done", "error"):
                break
        if chunk_count == 0:
            raise OpenAiLiveAudioUnavailable("OpenAI Realtime returned no audio chunks.")
    except OpenAiLiveAudioUnavailable:
        raise
    except Exception as exc:  # noqa: BLE001
        raise OpenAiLiveAudioUnavailable("OpenAI Realtime audio streaming failed.") from exc
    finally:
        try:
            await ws.close()
        except Exception:  # noqa: BLE001
            pass


# ---- 실시간 STT (입력 전사) ----

def _resample_pcm16(pcm: bytes, src_rate: int, dst_rate: int) -> bytes:
    """pcm16 mono를 src_rate→dst_rate로 선형보간 리샘플(청크 단위, STT 충분 품질)."""
    if src_rate == dst_rate or not pcm:
        return pcm
    samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
    n_in = len(samples)
    if n_in == 0:
        return pcm
    n_out = max(1, round(n_in * dst_rate / src_rate))
    out = []
    for i in range(n_out):
        pos = i * src_rate / dst_rate
        i0 = int(pos)
        frac = pos - i0
        a = samples[i0] if i0 < n_in else samples[-1]
        b = samples[i0 + 1] if i0 + 1 < n_in else a
        out.append(max(-32768, min(32767, int(a + (b - a) * frac))))
    return struct.pack(f"<{len(out)}h", *out)


@asynccontextmanager
async def open_openai_stt_session(*, sample_rate: int = _STT_SESSION_RATE):
    """OpenAI Realtime 전사 세션을 열고 session.update(전사 설정)까지 마친 소켓을 준다.

    세션 입력 포맷은 항상 24kHz(_STT_SESSION_RATE)로 연다(OpenAI 최소 요구). 16k로 들어오는
    클라이언트 오디오는 openai_stt_audio_message에서 24k로 업샘플해 보낸다.
    """
    socket = await _connect(f"{_REALTIME_URL}?intent=transcription")
    try:
        await asyncio.wait_for(socket.recv(), timeout=6)  # session.created
        await socket.send(json.dumps({
            "type": "session.update",
            "session": {
                "type": "transcription",
                "audio": {"input": {
                    "format": {"type": "audio/pcm", "rate": _STT_SESSION_RATE},
                    "transcription": {"model": stt_model(), "language": "ko"},
                    "turn_detection": {"type": "server_vad", "silence_duration_ms": 500},
                }},
            },
        }))
        yield socket
    finally:
        try:
            await socket.close()
        except Exception:  # noqa: BLE001
            pass


def openai_stt_audio_message(*, b64_pcm16: str, sample_rate: int = 16000) -> dict:
    # 세션은 24kHz이므로 클라이언트 레이트(보통 16k)를 24k로 업샘플해 싣는다.
    if sample_rate != _STT_SESSION_RATE:
        try:
            raw = base64.b64decode(b64_pcm16)
            raw = _resample_pcm16(raw, int(sample_rate), _STT_SESSION_RATE)
            b64_pcm16 = base64.b64encode(raw).decode("ascii")
        except Exception:  # noqa: BLE001
            pass
    return {"type": "input_audio_buffer.append", "audio": b64_pcm16}


def openai_stt_stream_end_message() -> dict:
    return {"type": "input_audio_buffer.commit"}


def extract_openai_input_transcript(message: dict) -> tuple[str | None, bool]:
    """OpenAI 전사 이벤트에서 (증분 텍스트 또는 None, turnComplete)를 뽑는다.

    delta는 증분 조각이라 호출자가 버퍼에 누적, completed는 누적이 끝났다는 신호만 준다
    (전체 transcript를 다시 더하면 중복되므로 텍스트는 None으로 돌린다).
    """
    event_type = message.get("type")
    if event_type == "conversation.item.input_audio_transcription.delta":
        delta = message.get("delta")
        return (delta if isinstance(delta, str) and delta else None, False)
    if event_type == "conversation.item.input_audio_transcription.completed":
        return None, True
    return None, False
