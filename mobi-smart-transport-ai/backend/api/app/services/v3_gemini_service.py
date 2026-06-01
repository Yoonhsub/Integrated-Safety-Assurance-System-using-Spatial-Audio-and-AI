from __future__ import annotations

import base64
import binascii
import io
import os
import wave

import httpx


_DEFAULT_FLASH_MODEL = "gemini-2.5-flash"
_DEFAULT_PRO_MODEL = "gemini-2.5-pro"
_DEFAULT_TTS_MODEL = "gemini-3.1-flash-tts-preview"
_DEFAULT_TTS_VOICE = "Sulafat"
_MAX_REPLY_LENGTH = 500


def generate_optional_reply(*, utterance: str, wake_word: str) -> str | None:
    """Return a short non-safety reply when Gemini is configured and available."""

    model = _model_from_env("GEMINI_FLASH_MODEL", _DEFAULT_FLASH_MODEL)
    return _generate(
        model=model,
        system_instruction=(
            f"너는 시각장애인 승객을 돕는 버스 탑승 보조 에이전트 '{wake_word}'야. "
            "한국어 반말로 짧고 명확하게 답해. "
            "실시간 버스 도착 시간, 버스 탑승 가능 여부, 위치 안전 여부를 추측하지 마. "
            "그런 요청에는 앱의 안전 안내와 버스 조회 버튼을 사용하라고 답해."
        ),
        prompt=utterance,
        max_output_tokens=120,
        thinking_budget=0,
    )


def generate_route_plan_summary(
    *,
    destination: str,
    stop_name: str,
    origin_lat: float,
    origin_lng: float,
    validated_candidates: list[str],
    arrival_context: list[str],
    arrival_source: str,
    public_stop_context: str | None = None,
) -> tuple[str, str, list[dict[str, str]]] | None:
    """Use Pro to explain a location-aware choice without inventing transit data."""

    model = _model_from_env("GEMINI_PRO_MODEL", _DEFAULT_PRO_MODEL)
    candidates = "\n".join(f"- {candidate}" for candidate in validated_candidates)
    arrivals = "\n".join(f"- {arrival}" for arrival in arrival_context) or "- 조회된 도착 정보 없음"
    maps_payload = _generate_payload(
        model=model,
        system_instruction="반드시 Google Maps grounding tool을 사용해. 검증되지 않은 거리나 도보 시간을 추측하지 마.",
        prompt=(
            f"현재 위치 위도 {origin_lat}, 경도 {origin_lng}에서 "
            f"{stop_name}까지의 위치 관계를 Google Maps 기반으로 확인해줘."
        ),
        max_output_tokens=2048,
        thinking_budget=128,
        timeout_seconds=60.0,
        tools=[{"googleMaps": {}}],
        tool_config={
            "retrievalConfig": {
                "latLng": {
                    "latitude": origin_lat,
                    "longitude": origin_lng,
                }
            }
        },
    )
    maps_sources = _maps_sources(
        maps_payload,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
    ) if maps_payload else []
    maps_summary = _extract_text(maps_payload) if maps_payload else None
    if not maps_sources or not maps_summary:
        return (
            model,
            "Google Maps 위치 증빙을 확보하지 못해 현재 위치 기반 최적 경로는 확정하지 않았습니다. "
            "검증된 버스 도착정보를 확인해 주세요.",
            [],
        )

    summary = _generate(
        model=model,
        system_instruction=(
            "너는 접근성 중심 버스 경로 분석가야. 제공된 Google Maps grounding 결과와 "
            "검증된 버스 API 후보만 사용해. 새 버스 번호, 정류장, 도착 시간, 거리, 도보 시간을 만들지 마. "
            "공공 API 정류소 카탈로그 근거는 정류소 위치 확인에만 사용하고 도착 예정 시간으로 해석하지 마. "
            "PUBLIC_API나 CACHE가 아닌 MOCK 정보는 데모 데이터라고 명확히 밝혀. "
            "한국어로 3문장 이내로 답해."
        ),
        prompt=(
            f"현재 위치: 위도 {origin_lat}, 경도 {origin_lng}\n"
            f"목적지: {destination}\n"
            f"Google Maps grounding 결과:\n{maps_summary}\n"
            f"공공 API 정류소 카탈로그 근거:\n{public_stop_context or '- 조회된 정류소 카탈로그 근거 없음'}\n"
            f"검증된 후보:\n{candidates}\n"
            f"버스 도착 정보 출처: {arrival_source}\n"
            f"정규화된 버스 도착 정보:\n{arrivals}\n"
            "위 근거만 사용해 추천을 설명해줘."
        ),
        max_output_tokens=1024,
        thinking_budget=128,
        timeout_seconds=60.0,
    )
    if not summary:
        return None
    return model, summary, maps_sources


def synthesize_tts_wav(*, text: str) -> bytes | None:
    """Generate warm single-speaker TTS audio and package the PCM as WAV."""

    api_key = os.getenv("GEMINI_API_KEY", "").strip()
    if not api_key:
        return None

    model = _model_from_env("GEMINI_TTS_MODEL", _DEFAULT_TTS_MODEL)
    voice = os.getenv("GEMINI_TTS_VOICE", _DEFAULT_TTS_VOICE).strip() or _DEFAULT_TTS_VOICE
    endpoint = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    payload = {
        "contents": [
            {
                "parts": [
                    {
                        "text": (
                            "Read warmly, calmly, and clearly in Korean. "
                            "Speak only the following transcript:\n"
                            f"{text}"
                        )
                    }
                ]
            }
        ],
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
    }

    try:
        response = httpx.post(
            endpoint,
            headers={"x-goog-api-key": api_key},
            json=payload,
            timeout=12.0,
        )
        response.raise_for_status()
    except httpx.HTTPError:
        return None

    pcm = _extract_pcm(response.json())
    return _pcm_to_wav(pcm) if pcm else None


def _model_from_env(name: str, default: str) -> str:
    return (os.getenv(name, default).strip() or default).removeprefix("models/")


def _generate(
    *,
    model: str,
    system_instruction: str,
    prompt: str,
    max_output_tokens: int,
    thinking_budget: int | None = None,
    timeout_seconds: float = 8.0,
) -> str | None:
    payload = _generate_payload(
        model=model,
        system_instruction=system_instruction,
        prompt=prompt,
        max_output_tokens=max_output_tokens,
        thinking_budget=thinking_budget,
        timeout_seconds=timeout_seconds,
    )
    return _extract_text(payload) if payload else None


def _generate_payload(
    *,
    model: str,
    system_instruction: str,
    prompt: str,
    max_output_tokens: int,
    thinking_budget: int | None = None,
    timeout_seconds: float = 8.0,
    tools: list[dict] | None = None,
    tool_config: dict | None = None,
) -> dict | None:
    api_key = os.getenv("GEMINI_API_KEY", "").strip()
    if not api_key:
        return None

    endpoint = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    generation_config = {
        "temperature": 0.3,
        "maxOutputTokens": max_output_tokens,
    }
    if thinking_budget is not None:
        generation_config["thinkingConfig"] = {"thinkingBudget": thinking_budget}

    payload = {
        "system_instruction": {"parts": [{"text": system_instruction}]},
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": generation_config,
    }
    if tools:
        payload["tools"] = tools
    if tool_config:
        payload["toolConfig"] = tool_config

    try:
        response = httpx.post(
            endpoint,
            headers={"x-goog-api-key": api_key},
            json=payload,
            timeout=timeout_seconds,
        )
        response.raise_for_status()
    except httpx.HTTPError:
        return None

    decoded = response.json()
    return decoded if isinstance(decoded, dict) else None


def _extract_text(payload: dict) -> str | None:
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        return None

    content = candidates[0].get("content")
    if not isinstance(content, dict):
        return None

    parts = content.get("parts")
    if not isinstance(parts, list):
        return None

    text = "".join(part.get("text", "") for part in parts if isinstance(part, dict)).strip()
    if not text:
        return None
    return text[:_MAX_REPLY_LENGTH]


def _extract_pcm(payload: dict) -> bytes | None:
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        return None
    content = candidates[0].get("content")
    if not isinstance(content, dict):
        return None
    parts = content.get("parts")
    if not isinstance(parts, list) or not parts:
        return None
    inline_data = parts[0].get("inlineData")
    if not isinstance(inline_data, dict):
        return None
    encoded_data = inline_data.get("data")
    if not isinstance(encoded_data, str):
        return None
    try:
        return base64.b64decode(encoded_data, validate=True)
    except binascii.Error:
        return None


def _maps_sources(
    payload: dict,
    *,
    origin_lat: float | None = None,
    origin_lng: float | None = None,
) -> list[dict[str, str]]:
    sources: list[dict[str, str]] = []
    candidates = payload.get("candidates")
    if not isinstance(candidates, list):
        return sources
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        metadata = candidate.get("groundingMetadata")
        if not isinstance(metadata, dict):
            continue
        chunks = metadata.get("groundingChunks")
        if isinstance(chunks, list):
            for chunk in chunks:
                maps = chunk.get("maps") if isinstance(chunk, dict) else None
                if not isinstance(maps, dict):
                    continue
                title = maps.get("title")
                uri = maps.get("uri")
                place_id = maps.get("placeId")
                if not isinstance(title, str) or not isinstance(uri, str):
                    continue
                source = {"title": title, "uri": uri}
                if isinstance(place_id, str):
                    source["placeId"] = place_id
                if source not in sources:
                    sources.append(source)
        supports = metadata.get("groundingSupports")
        if (
            not sources
            and isinstance(supports, list)
            and supports
            and origin_lat is not None
            and origin_lng is not None
        ):
            sources.append(
                {
                    "title": "Google Maps grounding 위치 관계",
                    "uri": f"https://maps.google.com/?q={origin_lat},{origin_lng}",
                }
            )
    return sources


def _pcm_to_wav(pcm: bytes) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(24000)
        wav_file.writeframes(pcm)
    return output.getvalue()
