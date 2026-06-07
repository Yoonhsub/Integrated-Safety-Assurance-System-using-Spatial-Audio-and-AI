from __future__ import annotations

import base64
import binascii
import io
import json
import os
import re
import wave

import httpx


_DEFAULT_FLASH_MODEL = "gemini-2.5-flash"
_DEFAULT_PRO_MODEL = "gemini-2.5-pro"
_DEFAULT_PRO_TTS_MODEL = "gemini-2.5-pro-preview-tts"
_DEFAULT_FLASH_TTS_MODEL = "gemini-3.1-flash-tts-preview"
_LEGACY_FLASH_TTS_MODEL = "gemini-2.5-flash-preview-tts"
_DEFAULT_TTS_VOICE = "Kore"
_MAX_REPLY_LENGTH = 500
_GROUNDED_TRANSIT_RULE = (
    "너는 교통 정보를 추측하지 않는다. 제공된 routePlan, arrivals, busLocations, "
    "serviceStatus, destination resolution JSON에 있는 정보만 설명한다. 값이 없으면 없다고 말한다. "
)
_POLITE_REPLY_STYLE = (
    "사용자에게 말하는 최종 답변은 항상 정중한 존댓말로 써. "
    "문장 끝은 '-입니다/-습니다'와 '-예요/-요'를 자연스럽게 섞고, 모든 문장을 '-요'로만 끝내지 마. "
    "'~야', '~어', '~돼', '~했어', '~줄게' 같은 반말 종결은 쓰지 마. "
)
_VISION_REQUIRED_TERMS = (
    "건너편",
    "오른쪽 정류장",
    "오른쪽에 있는 정류장",
    "왼쪽 정류장",
    "왼쪽에 있는 정류장",
    "횡단보도",
    "도로를 건너",
    "도로 건너",
    "길을 건너",
    "길 건너",
)

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
    "END_CONVERSATION",
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
    history: list[dict] | None = None,
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
        "- destination: 발화에 목적지가 있으면 사용자가 말한 장소명/주소/정류장명 원문을 짧게 추출하고, 없으면 null\n"
        f"참고용으로 이미 안정화된 목적지 이름은 다음과 같아 — {', '.join(known_destinations)}\n"
        "의도 가이드: 길/노선/몇번/가는법=FIND_ROUTE, 언제·몇분 뒤=QUERY_ARRIVAL, "
        "지금 이 버스 타도 되냐=ASK_CAN_BOARD_CURRENT_BUS, 놓쳤다·못 탔다=REPORT_MISSED_BUS, "
        "목적지 바꿔=CHANGE_DESTINATION, 'A 아니라 B'=CORRECT_DESTINATION, "
        "안내 시작·이걸로 해줘=SELECT_ARRIVAL, 호출어만 부름=WAKE_ONLY, "
        "대화를 끝내거나 그만하고 싶어함·작별 인사·'됐어 그만'·'이제 괜찮아'·'나중에 또 부를게'="
        "END_CONVERSATION(키워드가 아니라 종료하려는 의사가 보이면 분류), 그 외 잡담=UNKNOWN."
    )
    raw = _generate(
        model=model,
        system_instruction=system_instruction,
        prompt=utterance,
        max_output_tokens=120,
        thinking_budget=0,
        history=history,
    )
    if not raw:
        return None
    return _parse_classification(raw, known_destinations)


def infer_cheongju_destination(
    *,
    heard_text: str,
    known_destinations: tuple[str, ...],
) -> str | None:
    """오인식된 목적지를 청주시 내 실제 지명 후보 하나로 추론한다.

    반환값은 '추측'일 뿐이며, 호출자가 반드시 우리 API(resolver)로 실재를 검증한 뒤에만
    사용해야 한다. 검증되지 않은 임의 지명을 그대로 사용자에게 묻지 않는다.
    Gemini 미설정/실패 시 None.
    """
    heard = (heard_text or "").strip()
    if not heard:
        return None
    model = _model_from_env("GEMINI_FLASH_MODEL", _DEFAULT_FLASH_MODEL)
    system_instruction = (
        "너는 충청북도 청주시 지리 보조야. 사용자가 음성으로 말한 목적지가 STT 오인식 등으로 "
        "실제와 다를 수 있어. 발음·표기가 가장 비슷하면서 '청주시'에 실제로 존재하는 "
        "장소·정류장·교차로·지명 후보를 딱 하나만 추론해. 반드시 청주 안의 실제 지명만 대고, "
        "추측이 어려우면 null을 줘. 다른 도시 지명이나 없는 곳을 지어내지 마. "
        'JSON 객체 하나만 출력: {"guess": "<청주 지명>"} 또는 {"guess": null}\n'
        f"참고용 알려진 청주 목적지: {', '.join(known_destinations)}"
    )
    raw = _generate(
        model=model,
        system_instruction=system_instruction,
        prompt=heard,
        max_output_tokens=48,
        thinking_budget=0,
    )
    if not raw:
        return None
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
    guess = data.get("guess")
    if not isinstance(guess, str):
        return None
    guess = guess.strip()
    return guess or None


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
    if isinstance(destination, str):
        destination = destination.strip() or None
    else:
        destination = None

    return {"intent": intent, "complexity": complexity, "destination": destination}


def generate_optional_reply(
    *,
    utterance: str,
    wake_word: str,
    history: list[dict] | None = None,
    pending_question: str | None = None,
) -> str | None:
    """Return a short non-safety reply when Gemini is configured and available.

    ``pending_question``: 직전에 에이전트가 사용자에게 한 목적지 확인/선택 질문. 사용자가
    그 안에 나온 장소 이름의 뜻을 되물을 때, 일반 상식(뉴스사·통신사 등)으로 새지 않고
    '그건 청주의 목적지 후보'라고 맥락에 맞게 설명하도록 모델에 컨텍스트를 준다.
    """

    model = _model_from_env("GEMINI_FLASH_MODEL", _DEFAULT_FLASH_MODEL)
    pending_context = (
        (
            f' 방금 네가 사용자에게 한 목적지 확인 질문은 "{pending_question}"였어. '
            "사용자가 그 질문에 나온 장소 이름이 뭐냐고 되물으면, 그건 청주 안의 한 장소(목적지 후보)라고 "
            "설명하고 거기로 안내할지 다시 물어. 뉴스통신사·회사 같은 무관한 뜻으로 설명하지 마."
        )
        if pending_question
        else ""
    )
    reply = _generate(
        model=model,
        system_instruction=(
            f"너는 시각장애인 승객을 돕는 버스 탑승 보조 에이전트 '{wake_word}'야. "
            f"{_POLITE_REPLY_STYLE}"
            "짧고 명확하게 답해. "
            "이전 대화 맥락을 기억하고 이어서 자연스럽게 답해. "
            "실시간 버스 도착 시간, 버스 탑승 가능 여부, 위치 안전 여부를 추측하지 마. "
            "그런 요청에는 앱의 안전 안내와 버스 조회 버튼을 사용하라고 답해. "
            "버스 안내·길찾기와 무관한 일반 상식이나 사실 질문(뉴스·인물·용어 정의 등)에는 "
            "백과사전처럼 길게 답하지 말고, '그건 제가 잘 모르겠어요. 버스 길안내를 도와드릴게요'처럼 "
            "짧게 답한 뒤 목적지 안내로 돌아와."
            + pending_context
        ),
        prompt=utterance,
        max_output_tokens=120,
        thinking_budget=0,
        history=history,
    )
    return _without_vision_claims(reply)


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
        timeout_seconds=8.0,
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
            f"{_POLITE_REPLY_STYLE}"
            "3문장 이내로 답해."
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
        timeout_seconds=6.0,
    )
    summary = _without_vision_claims(summary)
    if not summary:
        return None
    return model, summary, maps_sources


def generate_route_plan_reply(
    *,
    route_plan: dict,
    utterance: str,
    wake_word: str,
    history: list[dict] | None = None,
) -> str | None:
    """Use Gemini only to verbalize an already-computed RoutePlan JSON.

    Gemini must not create bus numbers, stops, arrivals, directions, or routes.
    Flash is a safe availability fallback when Pro is quota-limited.
    If the model output contains side-of-road claims that require vision, reject it
    and let the caller use deterministic fallback text.
    """
    model = _model_from_env("GEMINI_PRO_MODEL", _DEFAULT_PRO_MODEL)
    prompt = json.dumps(
        {
            "utterance": utterance,
            "routePlan": _route_plan_explanation_payload(route_plan),
        },
        ensure_ascii=False,
        indent=2,
    )
    instruction = (
        f"너는 시각장애인 승객을 돕는 버스 탑승 보조 에이전트 '{wake_word}'야. "
        f"{_GROUNDED_TRANSIT_RULE}"
        "You must not invent bus route numbers, stop names, arrival times, route IDs, node IDs, or directions. "
        "Only explain the provided RoutePlan JSON. If a field is missing or unknown, say it is unknown. "
        "입력으로 제공된 RoutePlan JSON에 있는 정보만 자연어로 설명해. "
        "새 버스번호, 정류장명, 도착시간, 환승지, 도보거리, 방향을 절대 만들지 마. "
        "status가 NEEDS_CONFIRMATION/NEEDS_CHOICE/NOT_FOUND/NO_ROUTE이면 question만 자연스럽게 말해. "
        "status가 RESOLVED이면 recommendedPlan.summary, boardingInstruction, 첫 segment의 arrivals만 사용해. "
        "recommendedPlan.verificationStatus와 warnings를 확인해. ODSAY_ONLY 또는 PARTIAL이면 TAGO 실시간 정보로 검증됐다고 말하지 마. "
        "arrival이 없거나 첫 segment의 arrivals가 비어 있으면 도착시간을 만들지 말고 확인하지 못했다고 말해. "
        "directionHint가 없으면 임의 방향을 만들지 말고 정류장 표지판을 확인해 달라고 말해. "
        "현재 단계에서는 '건너편 정류장', '오른쪽 정류장', '횡단보도를 건너라'처럼 비전 검증이 필요한 표현을 쓰지 마. "
        f"{_POLITE_REPLY_STYLE}"
        "2문장 이내로 답해."
    )
    reply = _generate(
        model=model,
        system_instruction=instruction,
        prompt=prompt,
        max_output_tokens=220,
        # gemini-2.5-pro는 thinkingBudget=0을 거부할 수 있으므로 최소 thinking budget을 둔다.
        thinking_budget=128,
        # 프론트 converse 타임아웃(60s) 안에 Pro+Flash 폴백이 모두 끝나도록 짧게 잡는다.
        timeout_seconds=6.0,
        history=history,
    )
    if not reply:
        flash_model = _model_from_env("GEMINI_FLASH_MODEL", _DEFAULT_FLASH_MODEL)
        if flash_model != model:
            reply = _generate(
                model=flash_model,
                system_instruction=instruction,
                prompt=prompt,
                max_output_tokens=220,
                thinking_budget=128,
                timeout_seconds=5.0,
                history=history,
            )
    if not reply:
        return None
    return _without_vision_claims(reply)


def _route_plan_explanation_payload(route_plan: dict) -> dict:
    """Keep Gemini on the verified recommendation instead of provider evidence."""
    recommended = route_plan.get("recommendedPlan")
    if not isinstance(recommended, dict):
        return {
            "status": route_plan.get("status"),
            "question": route_plan.get("question"),
            "warnings": route_plan.get("warnings") or [],
        }

    raw_segments = recommended.get("segments")
    segments: list[dict] = []
    if isinstance(raw_segments, list):
        for index, raw_segment in enumerate(raw_segments):
            if not isinstance(raw_segment, dict):
                continue
            segments.append(
                {
                    "routeNo": raw_segment.get("routeNo"),
                    "routeId": raw_segment.get("routeId"),
                    "boardStop": raw_segment.get("boardStop"),
                    "alightStop": raw_segment.get("alightStop"),
                    "directionHint": raw_segment.get("directionHint"),
                    "arrivals": raw_segment.get("arrivals") if index == 0 else [],
                    "arrivalUnknown": raw_segment.get("arrivalUnknown"),
                    "serviceStatus": raw_segment.get("serviceStatus"),
                }
            )
    return {
        "status": route_plan.get("status"),
        "warnings": route_plan.get("warnings") or [],
        "recommendedPlan": {
            "planSource": recommended.get("planSource"),
            "verificationStatus": recommended.get("verificationStatus"),
            "summary": recommended.get("summary"),
            "boardingInstruction": recommended.get("boardingInstruction"),
            "warnings": recommended.get("warnings") or [],
            "segments": segments,
        },
    }


def generate_dynamic_response(
    *,
    intent: str,
    utterance: str,
    wake_word: str,
    context_data: dict,
    history: list[dict] | None = None,
) -> str | None:
    """Use Pro to generate a natural conversational response based on live API data."""
    model = _model_from_env("GEMINI_PRO_MODEL", _DEFAULT_PRO_MODEL)

    system_instruction = (
        f"너는 시각장애인 승객을 돕는 버스 탑승 보조 에이전트 '{wake_word}'야. "
        f"{_GROUNDED_TRANSIT_RULE}"
        f"{_POLITE_REPLY_STYLE}"
        "짧고 명확하게 답해. 절대 구구절절 설명하지 말고 2문장 이내로 말해. "
        "이전 대화 맥락을 기억하고 이어서 자연스럽게 답해. "
        "제공된 실시간 공공 API 데이터(context_data)에 기반해서만 대답하고, 정보가 부족하면 "
        "솔직하게 정보가 없다고 말해."
    )

    prompt = (
        f"사용자 의도: {intent}\n"
        f"사용자 발화: {utterance}\n"
        f"실시간 API 컨텍스트 데이터:\n{context_data}\n\n"
        "이 데이터를 바탕으로 사용자의 질문에 짧고 명확한 존댓말로 대답해줘."
    )

    reply = _generate(
        model=model,
        system_instruction=system_instruction,
        prompt=prompt,
        max_output_tokens=150,
        # gemini-2.5-pro는 thinking 비활성화(budget 0)를 거부한다("only works in thinking mode").
        # 복잡 응답은 Pro로 처리하므로 최소 thinking budget을 부여해야 실제 응답이 생성된다.
        thinking_budget=128,
        # 프론트 converse 타임아웃(60s) 안에 끝나도록 짧게 잡는다.
        timeout_seconds=4.0,
        history=history,
    )
    return _without_vision_claims(reply)


def _without_vision_claims(reply: str | None) -> str | None:
    if not reply or any(term in reply for term in _VISION_REQUIRED_TERMS):
        return None
    cleaned = _remove_mobi_user_address(reply)
    return cleaned or None


def _remove_mobi_user_address(reply: str) -> str:
    if "모비야" not in reply:
        return reply
    cleaned = re.sub(r"^(?:그래|네|응)?[\s,，]*모비야[.!?]?\s*", "", reply).strip()
    cleaned = re.sub(r"(?<!나는 )모비야\s*[,，]\s*", "", cleaned).strip()
    return cleaned


def synthesize_tts_wav(*, text: str) -> bytes | None:
    """Generate warm single-speaker TTS audio and package the PCM as WAV."""

    api_key = os.getenv("GEMINI_API_KEY", "").strip()
    if not api_key:
        return None

    configured_model = os.getenv("GEMINI_TTS_MODEL", "").strip().removeprefix("models/")
    candidate_models = _dedupe(
        [
            configured_model,
            _DEFAULT_PRO_TTS_MODEL,
            _DEFAULT_FLASH_TTS_MODEL,
            _LEGACY_FLASH_TTS_MODEL,
        ]
    )

    voice = os.getenv("GEMINI_TTS_VOICE", _DEFAULT_TTS_VOICE).strip() or _DEFAULT_TTS_VOICE
    payload = {
        "contents": [
            {
                "parts": [
                    {
                        "text": (
                            "Speak the following Korean text like a warm, friendly real person talking "
                            "right next to the listener — lively and genuinely human, with natural "
                            "conversational intonation, natural rhythm, and brief natural pauses. Never flat, "
                            "monotone, or robotic. The text is polite Korean (존댓말); keep that warm, "
                            "respectful, polite tone, clear and easy to understand. "
                            "Speak ONLY this transcript, do not add, change, or answer anything:\n"
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

    for model in candidate_models:
        endpoint = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        try:
            response = httpx.post(
                endpoint,
                headers={"x-goog-api-key": api_key},
                json=payload,
                timeout=12.0,
            )
            response.raise_for_status()
        except httpx.HTTPError:
            continue

        pcm = _extract_pcm(response.json())
        if pcm:
            return _pcm_to_wav(pcm)
    return None


def _model_from_env(name: str, default: str) -> str:
    return (os.getenv(name, default).strip() or default).removeprefix("models/")


def _dedupe(values: list[str]) -> list[str]:
    return list(dict.fromkeys(value for value in values if value))


def _generate(
    *,
    model: str,
    system_instruction: str,
    prompt: str,
    max_output_tokens: int,
    thinking_budget: int | None = None,
    timeout_seconds: float = 5.0,
    history: list[dict] | None = None,
) -> str | None:
    payload = _generate_payload(
        model=model,
        system_instruction=system_instruction,
        prompt=prompt,
        max_output_tokens=max_output_tokens,
        thinking_budget=thinking_budget,
        timeout_seconds=timeout_seconds,
        history=history,
    )
    return _extract_text(payload) if payload else None


def _history_contents(history: list[dict] | None) -> list[dict]:
    """이전 대화 턴을 Gemini contents 형식(user/model 교대)으로 변환한다.

    history 항목은 ``{"role": "user"|"model", "text": str}`` 형태를 기대한다.
    대화창을 초기화하기 전까지 에이전트가 맥락을 기억하도록 현재 발화 앞에 붙인다.
    """
    if not history:
        return []
    contents: list[dict] = []
    for turn in history:
        if not isinstance(turn, dict):
            continue
        role = turn.get("role")
        text = turn.get("text")
        if role not in {"user", "model"} or not isinstance(text, str) or not text.strip():
            continue
        contents.append({"role": role, "parts": [{"text": text.strip()}]})
    return contents


def _generate_payload(
    *,
    model: str,
    system_instruction: str,
    prompt: str,
    max_output_tokens: int,
    thinking_budget: int | None = None,
    timeout_seconds: float = 5.0,
    tools: list[dict] | None = None,
    tool_config: dict | None = None,
    history: list[dict] | None = None,
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
        "contents": [
            *_history_contents(history),
            {"role": "user", "parts": [{"text": prompt}]},
        ],
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
    inline_data = parts[0].get("inlineData") or parts[0].get("inline_data")
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
