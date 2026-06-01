from __future__ import annotations

import base64
import binascii
import io
import json
import os
import wave

import httpx


_DEFAULT_FLASH_MODEL = "gemini-2.5-flash"
_DEFAULT_PRO_MODEL = "gemini-2.5-pro"
_DEFAULT_TTS_MODEL = "gemini-3.1-flash-tts-preview"
_DEFAULT_TTS_VOICE = "Sulafat"
_MAX_REPLY_LENGTH = 500

# Flash 1차 분류가 돌려줄 수 있는 의도 라벨(AgentIntent와 1:1).
_INTENT_LABELS = (
    "WAKE_ONLY",
    "FIND_ROUTE",
    "QUERY_ARRIVAL",
    "SELECT_ARRIVAL",
    "ASK_CAN_BOARD_CURRENT_BUS",
    "REPORT_MISSED_BUS",
    "CORRECT_DESTINATION",
    "CHANGE_DESTINATION",
    "UNKNOWN",
)
# 실시간 공공 버스데이터가 필요한(=복잡) 의도. 나머지는 일반 대화로 본다.
_COMPLEX_INTENTS = frozenset(
    {
        "FIND_ROUTE",
        "QUERY_ARRIVAL",
        "SELECT_ARRIVAL",
        "ASK_CAN_BOARD_CURRENT_BUS",
        "REPORT_MISSED_BUS",
        "CORRECT_DESTINATION",
        "CHANGE_DESTINATION",
    }
)


def classify_intent(
    *,
    utterance: str,
    wake_word: str,
    known_destinations: tuple[str, ...],
) -> dict | None:
    """Flash로 발화의 복잡도/의도/목적지를 1차 분류한다.

    반환: ``{"intent": str, "complexity": "COMPLEX"|"GENERAL", "destination": str|None}``
    또는 Gemini 미설정/실패 시 ``None``.

    경로 탐색·도착·탑승 판단처럼 실시간 공공데이터가 필요한 발화는 ``COMPLEX``로 분류해
    호출자가 Gemini Pro 경로로 보내고, 인사·잡담 등은 ``GENERAL``로 분류해 Flash가
    바로 답하게 한다.
    """
    model = _model_from_env("GEMINI_FLASH_MODEL", _DEFAULT_FLASH_MODEL)
    system_instruction = (
        f"너는 시각장애인 버스 탑승 보조 에이전트 '{wake_word}'의 의도 분류기야. "
        "사용자 발화를 분석해 JSON 객체 하나만 출력해. 다른 설명은 절대 쓰지 마.\n"
        "필드:\n"
        f"- intent: 다음 중 하나 — {', '.join(_INTENT_LABELS)}\n"
        "- complexity: 실시간 공공 버스데이터(노선 탐색/도착시간/지금 탈 수 있는지/버스 위치)가 "
        ' 필요하면 "COMPLEX", 인사·감사·잡담·단순 확인이면 "GENERAL"\n'
        f"- destination: 발화에 목적지가 있으면 다음 목록 중 정확히 하나, 없으면 null — {', '.join(known_destinations)}\n"
        "의도 가이드: 길/노선/몇번/가는법=FIND_ROUTE, 언제·몇분 뒤=QUERY_ARRIVAL, "
        "지금 이 버스 타도 되냐=ASK_CAN_BOARD_CURRENT_BUS, 놓쳤다·못 탔다=REPORT_MISSED_BUS, "
        "목적지 바꿔=CHANGE_DESTINATION, 'A 아니라 B'=CORRECT_DESTINATION, "
        "안내 시작·이걸로 해줘=SELECT_ARRIVAL, 호출어만 부름=WAKE_ONLY, 그 외 잡담=UNKNOWN."
    )
    raw = _generate(
        model=model,
        system_instruction=system_instruction,
        prompt=utterance,
        max_output_tokens=120,
        thinking_budget=0,
    )
    if not raw:
        return None
    return _parse_classification(raw, known_destinations)


def _parse_classification(raw: str, known_destinations: tuple[str, ...]) -> dict | None:
    text = raw.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text[:4].lower() == "json":
            text = text[4:]
    try:
        start = text.index("{")
        end = text.rindex("}") + 1
        data = json.loads(text[start:end])
    except (ValueError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None

    intent = data.get("intent")
    if intent not in _INTENT_LABELS:
        intent = "UNKNOWN"

    complexity = data.get("complexity")
    if complexity not in {"COMPLEX", "GENERAL"}:
        complexity = "COMPLEX" if intent in _COMPLEX_INTENTS else "GENERAL"

    destination = data.get("destination")
    if destination not in known_destinations:
        destination = None

    return {"intent": intent, "complexity": complexity, "destination": destination}


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


def generate_dynamic_response(
    *,
    intent: str,
    utterance: str,
    wake_word: str,
    context_data: dict,
) -> str | None:
    """Use Pro to generate a natural conversational response based on live API data."""
    model = _model_from_env("GEMINI_PRO_MODEL", _DEFAULT_PRO_MODEL)
    
    system_instruction = (
        f"너는 시각장애인 승객을 돕는 버스 탑승 보조 에이전트 '{wake_word}'야. "
        "한국어 반말로 짧고 명확하게 답해. 절대 구구절절 설명하지 말고 2문장 이내로 말해. "
        "제공된 실시간 공공 API 데이터(context_data)에 기반해서만 대답하고, 정보가 부족하면 "
        "솔직하게 정보가 없다고 말해."
    )

    prompt = (
        f"사용자 의도: {intent}\n"
        f"사용자 발화: {utterance}\n"
        f"실시간 API 컨텍스트 데이터:\n{context_data}\n\n"
        "이 데이터를 바탕으로 사용자의 질문에 짧고 명확하게 반말로 대답해줘."
    )

    return _generate(
        model=model,
        system_instruction=system_instruction,
        prompt=prompt,
        max_output_tokens=150,
        # gemini-2.5-pro는 thinking 비활성화(budget 0)를 거부한다("only works in thinking mode").
        # 복잡 응답은 Pro로 처리하므로 최소 thinking budget을 부여해야 실제 응답이 생성된다.
        thinking_budget=128,
        timeout_seconds=30.0,
    )


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
