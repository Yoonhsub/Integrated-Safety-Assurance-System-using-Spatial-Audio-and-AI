from __future__ import annotations

import asyncio
import json
import os

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import Response
from pydantic import ValidationError

from app.schemas.v3 import (
    AgentConverseRequest,
    AgentConverseResponse,
    AgentIntent,
    AgentTtsRequest,
    BeaconDecision,
    CueType,
    FallbackSource,
    GuidanceState,
    RoutePlanReadiness,
    RoutePlanResponse,
    RoutePlanStatus,
    TtsMode,
    V3Cue,
)
from app.services import cheongju_route_catalog
from app.services.v3_agent_tools import (
    classify_agent_intent,
    get_arrivals_tool,
    get_bus_locations_tool,
    get_service_status_tool,
    match_pending_choice_tool,
    normalize_user_utterance,
    plan_transit_route_tool,
    sanitize_agent_reply_tool,
    verify_route_tool,
)
from app.services.v3_agent_trace import AgentTraceRecorder
from app.services.v3_gemini_service import (
    classify_intent,
    generate_dynamic_response,
    generate_optional_reply,
    infer_cheongju_destination,
    synthesize_tts_wav,
)
from app.services.v3_gemini_live_audio_service import (
    GeminiLiveAudioUnavailable,
    extract_input_transcript,
    live_audio_model,
    live_audio_voice,
    live_stt_audio_message,
    live_stt_audio_stream_end_message,
    open_gemini_stt_session,
    stream_live_audio_pcm,
)
from app.services.v3_guidance_store import V3SessionRecord, v3_guidance_store


def _is_live_mode() -> bool:
    return os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("false", "0", "no", "off")


def _resolve_live(mode: str | None) -> bool:
    """요청별 mode가 오면 그것을 우선 적용하고, 없으면 전역 env로 폴백한다."""
    if mode:
        return mode.strip().lower() == "live"
    return _is_live_mode()


router = APIRouter()

# 대화 맥락을 Gemini에 넘길 때 사용할 한도(토큰/지연을 적당히 묶기 위함).
_MAX_HISTORY_TURNS = 6
_MAX_HISTORY_CHARS = 300

_DESTINATION_ALIASES: tuple[tuple[str, str], ...] = (
    ("사창사거리", "사창사거리"),
    ("사창 사거리", "사창사거리"),
    ("사직사거리", "사창사거리"),
    ("충북대학교 병원", "충북대학교병원"),
    ("충북대학교병원", "충북대학교병원"),
    ("충북대병원", "충북대학교병원"),
    ("충대병원", "충북대학교병원"),
    ("청주고속버스터미널", "청주고속버스터미널"),
    ("청주 고속버스터미널", "청주고속버스터미널"),
    ("청주터미널", "청주고속버스터미널"),
    ("고속버스터미널", "청주고속버스터미널"),
    ("터미널", "청주고속버스터미널"),
)

@router.post("/tts", response_class=Response)
def tts(payload: AgentTtsRequest) -> Response:
    audio = synthesize_tts_wav(text=payload.text.strip())
    if audio is None:
        raise HTTPException(
            status_code=503,
            detail={
                "error": {
                    "code": "GEMINI_TTS_UNAVAILABLE",
                    "message": "Gemini TTS audio could not be generated.",
                    "detail": {},
                }
            },
        )
    return Response(
        content=audio,
        media_type="audio/wav",
        headers={"X-Gemini-TTS-Voice": os.getenv("GEMINI_TTS_VOICE", "Kore")},
    )


@router.websocket("/tts/live")
async def tts_live(websocket: WebSocket) -> None:
    """Proxy Gemini Live API PCM chunks without exposing the server API key."""

    await websocket.accept()
    try:
        payload = await asyncio.wait_for(websocket.receive_json(), timeout=5)
        request = AgentTtsRequest.model_validate(payload)
        await websocket.send_json(
            {
                "type": "start",
                "provider": "GEMINI_LIVE_API",
                "model": live_audio_model(),
                "voice": live_audio_voice(),
                "sampleRate": 24000,
                "channels": 1,
            }
        )
        chunk_count = 0
        async for chunk in stream_live_audio_pcm(text=request.text.strip()):
            chunk_count += 1
            await websocket.send_json(
                {
                    "type": "audio",
                    "data": chunk.data,
                    "mimeType": chunk.mime_type,
                }
            )
        await websocket.send_json({"type": "done", "chunkCount": chunk_count})
    except (asyncio.TimeoutError, ValidationError):
        await _send_live_audio_error(
            websocket,
            code="INVALID_LIVE_TTS_REQUEST",
            message="Live TTS request was missing or invalid.",
        )
    except GeminiLiveAudioUnavailable:
        await _send_live_audio_error(
            websocket,
            code="GEMINI_LIVE_TTS_UNAVAILABLE",
            message="Gemini Live API audio could not be generated.",
        )
    except Exception:
        await _send_live_audio_error(
            websocket,
            code="GEMINI_LIVE_TTS_ERROR",
            message="Live TTS streaming failed.",
        )
    finally:
        try:
            await websocket.close()
        except RuntimeError:
            pass


@router.websocket("/stt/live")
async def stt_live(websocket: WebSocket) -> None:
    """클라이언트 마이크 PCM을 Gemini Live API 입력 전사로 중계해 실시간 STT를 돌려준다.

    브라우저 Web Speech의 무제스처 재시작 제약을 우회하는 서버 STT 경로.
    클라이언트는 {type:'audio', data:<base64 pcm16>, sampleRate:16000} 를 계속 보내고,
    서버는 {type:'transcript', text, isFinal} 를 돌려준다. Gemini의 서버측 VAD가
    발화 종료(turnComplete)를 판정한다.
    """
    await websocket.accept()
    try:
        async with open_gemini_stt_session() as gemini:
            await websocket.send_json({"type": "ready"})

            # 두 펌프가 공유하는 전사 버퍼(턴 사이 reset으로 잔여 전사 분리).
            shared = {"buffer": ""}

            async def pump_client_to_gemini() -> None:
                while True:
                    msg = await websocket.receive_json()
                    kind = msg.get("type")
                    if kind == "audio":
                        data = msg.get("data")
                        if isinstance(data, str) and data:
                            sr = msg.get("sampleRate") or 16000
                            await gemini.send(
                                json.dumps(
                                    live_stt_audio_message(
                                        b64_pcm16=data, sample_rate=int(sr)
                                    )
                                )
                            )
                    elif kind == "reset":
                        # 새 턴 시작: 이전 턴 잔여 전사가 섞이지 않게 버퍼 비움.
                        shared["buffer"] = ""
                    elif kind == "stop":
                        try:
                            await gemini.send(
                                json.dumps(live_stt_audio_stream_end_message())
                            )
                        except Exception:  # noqa: BLE001
                            pass
                        return

            async def pump_gemini_to_client() -> None:
                # AUDIO 모달리티에선 turnComplete가 모델의 (무시할) 음성 응답 뒤에야 와서
                # 느리다. 그래서 입력 전사가 일정 시간 갱신되지 않으면(발화 종료) 확정한다.
                last_delta = 0.0
                loop = asyncio.get_running_loop()
                while True:
                    try:
                        raw = await asyncio.wait_for(gemini.recv(), timeout=0.25)
                    except asyncio.TimeoutError:
                        if shared["buffer"].strip() and (loop.time() - last_delta) >= 1.2:
                            await websocket.send_json(
                                {"type": "transcript", "text": shared["buffer"], "isFinal": True}
                            )
                            shared["buffer"] = ""
                        continue
                    try:
                        decoded = json.loads(raw)
                    except (TypeError, json.JSONDecodeError):
                        continue
                    if not isinstance(decoded, dict):
                        continue
                    text, turn_complete = extract_input_transcript(decoded)
                    if text:
                        shared["buffer"] += text
                        last_delta = loop.time()
                        await websocket.send_json(
                            {"type": "transcript", "text": shared["buffer"], "isFinal": False}
                        )
                    if turn_complete and shared["buffer"].strip():
                        await websocket.send_json(
                            {"type": "transcript", "text": shared["buffer"], "isFinal": True}
                        )
                        shared["buffer"] = ""

            tasks = [
                asyncio.create_task(pump_client_to_gemini()),
                asyncio.create_task(pump_gemini_to_client()),
            ]
            try:
                done, _ = await asyncio.wait(
                    tasks, return_when=asyncio.FIRST_COMPLETED
                )
                for task in done:
                    exc = task.exception()
                    if exc is not None:
                        import traceback

                        detail = "".join(
                            traceback.format_exception_only(type(exc), exc)
                        ).strip()
                        try:
                            await websocket.send_json(
                                {"type": "debug", "where": "pump", "detail": detail}
                            )
                        except Exception:  # noqa: BLE001
                            pass
            finally:
                for task in tasks:
                    task.cancel()
    except (WebSocketDisconnect, RuntimeError):
        pass
    except GeminiLiveAudioUnavailable:
        await _send_live_audio_error(
            websocket,
            code="GEMINI_LIVE_STT_UNAVAILABLE",
            message="Gemini Live STT could not be started.",
        )
    except Exception:  # noqa: BLE001
        await _send_live_audio_error(
            websocket,
            code="GEMINI_LIVE_STT_ERROR",
            message="Live STT streaming failed.",
        )
    finally:
        try:
            await websocket.close()
        except RuntimeError:
            pass


async def _send_live_audio_error(
    websocket: WebSocket,
    *,
    code: str,
    message: str,
) -> None:
    try:
        await websocket.send_json(
            {
                "type": "error",
                "code": code,
                "message": message,
            }
        )
    except RuntimeError:
        pass


# 처리 단계를 사용자용 'thought' 한 줄로 매핑(생각 사슬 스트리밍).
_THOUGHT_ON_START = {
    "NORMALIZE_UTTERANCE": "요청을 받았어. 무슨 말인지 정리하는 중...",
    "CLASSIFY_INTENT": "무엇을 원하는지 파악하는 중...",
    "DESTINATION_RESOLVE": "목적지를 공공데이터에서 확인하는 중...",
    "KAKAO_PLACE_SEARCH": "장소를 검색하는 중...",
    "NEARBY_STOP_SEARCH": "근처 정류장을 찾는 중...",
    "NEAR_DESTINATION_GUARD": "목적지가 가까운지 확인하는 중...",
    "ODSAY_ROUTE_SEARCH": "대중교통 경로를 계산하는 중...",
    "TAGO_ROUTE_VERIFY": "버스 노선을 검증하는 중...",
    "TAGO_ARRIVAL_LOOKUP": "실시간 도착정보를 확인하는 중...",
    "TAGO_BUS_LOCATION_LOOKUP": "버스 위치를 확인하는 중...",
    "SERVICE_STATUS_CHECK": "운행 상태를 확인하는 중...",
    "DESTINATION_INFERENCE": "정확히 같은 곳이 없네. 비슷한 청주 지역을 추론하는 중...",
}


def _thought_for_event(phase: str, event) -> str | None:
    if phase == "start":
        return _THOUGHT_ON_START.get(event.type)
    if phase == "end" and event.type == "DESTINATION_INFERENCE" and event.status == "DONE":
        verified = (event.safePayload or {}).get("verified")
        if isinstance(verified, str) and verified:
            return f"혹시 {verified}를 말씀하신 걸까요? 확인해 보겠습니다."
    return None


@router.websocket("/converse/live")
async def converse_live(websocket: WebSocket) -> None:
    """대화 처리 단계를 실시간 'thought'로 스트리밍하고 마지막에 최종 응답을 보낸다."""
    await websocket.accept()
    try:
        raw = await asyncio.wait_for(websocket.receive_json(), timeout=10)
        payload = AgentConverseRequest.model_validate(raw)
    except (asyncio.TimeoutError, ValidationError):
        await _send_live_audio_error(
            websocket,
            code="INVALID_CONVERSE_REQUEST",
            message="Converse request was missing or invalid.",
        )
        try:
            await websocket.close()
        except RuntimeError:
            pass
        return

    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def listener(phase: str, event) -> None:
        text = _thought_for_event(phase, event)
        if text:
            loop.call_soon_threadsafe(queue.put_nowait, ("thought", text))

    trace = AgentTraceRecorder(listener=listener)

    async def run() -> None:
        try:
            response = await asyncio.to_thread(_run_converse, payload, trace=trace)
            loop.call_soon_threadsafe(queue.put_nowait, ("final", response))
        except Exception:  # noqa: BLE001
            loop.call_soon_threadsafe(queue.put_nowait, ("error", None))

    task = asyncio.create_task(run())
    min_gap = 0.8
    last_emit = 0.0
    sent: set[str] = set()
    emitted = 0
    final_response: AgentConverseResponse | None = None
    errored = False
    try:
        while True:
            kind, value = await queue.get()
            if kind == "thought":
                if value in sent or emitted >= 9:
                    continue
                gap = min_gap - (loop.time() - last_emit)
                if gap > 0:
                    await asyncio.sleep(gap)
                last_emit = loop.time()
                sent.add(value)
                emitted += 1
                await websocket.send_json({"type": "thought", "text": value})
            elif kind == "final":
                final_response = value
                break
            else:
                errored = True
                break
        if errored or final_response is None:
            await _send_live_audio_error(
                websocket,
                code="CONVERSE_FAILED",
                message="Conversation processing failed.",
            )
        else:
            await websocket.send_json(
                {
                    "type": "final",
                    "response": final_response.model_dump(mode="json", by_alias=True),
                }
            )
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        try:
            await task
        except Exception:  # noqa: BLE001
            pass
        try:
            await websocket.close()
        except RuntimeError:
            pass


@router.post("/converse", response_model=AgentConverseResponse)
def converse(payload: AgentConverseRequest) -> AgentConverseResponse:
    return _run_converse(payload, trace=AgentTraceRecorder())


def _run_converse(
    payload: AgentConverseRequest,
    *,
    trace: AgentTraceRecorder,
) -> AgentConverseResponse:
    session = v3_guidance_store.get(payload.sessionId, wake_word=payload.wakeWord)
    wake_word = session.wake_word.strip()
    normalize_event = trace.start(
        "NORMALIZE_UTTERANCE",
        "사용자 발화 정리",
        operation="normalizeUserUtterance",
    )
    normalized = normalize_user_utterance(payload.utterance, wake_word=wake_word)
    trace.done(
        normalize_event,
        "호출어를 제거하고 목적지 후보 문장을 정리했어.",
        safe_payload={
            "wakeWordDetected": normalized.wake_word_detected,
            "cleanedUtterance": normalized.cleaned_utterance,
            "destinationText": normalized.destination_candidate_text,
        },
    )
    utterance = normalized.cleaned_utterance or payload.utterance.strip()
    live = _resolve_live(payload.mode)

    # 목적지 후보 확인/선택 질문이 걸린 상태에서는 "응 맞아", "두 번째" 같은 후속 발화를
    # 먼저 소비한다. Flash/Gemini가 이 짧은 답변을 잡담으로 오분류하는 것을 막기 위함이다.
    if session.pending_resolution_status and _is_explicit_new_route_request(utterance, wake_word):
        _clear_pending(session)
        trace.record(
            "PENDING_CHOICE_MATCH",
            "이전 후보 선택 상태 정리 완료",
            "새 목적지 요청을 감지해 이전 후보 선택 상태를 정리했어.",
        )
    pending_response = _try_answer_pending_destination(session, payload, live=live, trace=trace)
    if pending_response is not None:
        return pending_response
    if not session.pending_resolution_status:
        trace.skip(
            "PENDING_CHOICE_MATCH",
            "후보 선택 확인",
            "대기 중인 목적지 후보가 없어 선택 처리를 생략했어.",
        )

    history = _conversation_history_for_gemini(session)
    intent_event = trace.start(
        "CLASSIFY_INTENT",
        "요청 의도 분류",
        operation="classifyAgentIntent",
    )
    keyword_intent = classify_agent_intent(
        payload.utterance,
        session.to_response(),
        wake_word=wake_word,
    ).intent
    contextual_reply_hint = (
        _contextual_followup_reply(session=session, utterance=utterance)
        if keyword_intent == AgentIntent.UNKNOWN
        else None
    )
    # Deterministic route keywords and selected-route follow-ups should not wait
    # for Gemini. Flash is useful only when the local classifier is uncertain.
    classification = (
        classify_intent(
            utterance=utterance,
            wake_word=wake_word,
            known_destinations=cheongju_route_catalog.DESTINATIONS,
            history=history,
        )
        if keyword_intent == AgentIntent.UNKNOWN and contextual_reply_hint is None
        else None
    )
    intent = keyword_intent
    nlp_destination: str | None = None
    reasoning_source = "context" if contextual_reply_hint else "keyword"
    if classification is not None and classification["intent"] != AgentIntent.UNKNOWN.value:
        intent = AgentIntent(classification["intent"])
        nlp_destination = classification["destination"]
        reasoning_source = "gemini"
    trace.done(
        intent_event,
        "발화 의도를 먼저 추론한 뒤 처리 단계로 넘어갔어.",
        safe_payload={
            "intent": intent.value,
            "destinationText": nlp_destination,
            "reasoningSource": reasoning_source,
            "keywordIntent": keyword_intent.value,
            "historyTurns": len(history) // 2,
        },
    )

    message = "요청을 이해하지 못했어요. 버튼으로 다시 선택해 주세요."
    tts_mode = TtsMode.LOCAL_TTS
    cue = V3Cue(type=CueType.NONE, ttsMode=TtsMode.NONE)
    used_gemini = False
    fallback_source = FallbackSource.MOCK
    route_plan: RoutePlanResponse | None = None

    if intent == AgentIntent.WAKE_ONLY:
        message = "네, 말씀하세요."

    elif intent == AgentIntent.END_CONVERSATION:
        # 종료 의사는 Gemini가 자연어로 판별한다(키워드 매칭 아님).
        message = "지금 수행할 작업이 없는 것 같아요. 언제든 필요하면 불러 주세요."

    elif intent in {AgentIntent.FIND_ROUTE, AgentIntent.CHANGE_DESTINATION, AgentIntent.CORRECT_DESTINATION}:
        route_plan, message, tts_mode, used_gemini, fallback_source = _handle_route_request(
            session=session,
            payload=payload,
            intent=intent,
            nlp_destination=nlp_destination,
            live=live,
            trace=trace,
            history=history,
        )

    elif intent == AgentIntent.QUERY_ARRIVAL:
        selected = _selected_arrival_target(session)
        if selected is None:
            message = "먼저 목적지 경로를 선택해 주세요. 선택한 경로가 있어야 도착정보를 다시 확인할 수 있어요."
            fallback_source = FallbackSource.ERROR
        else:
            route_no, route_id, stop_id, stop_name = selected
            try:
                arrivals_res = get_arrivals_tool(
                    stop_id=stop_id,
                    route_no=route_no,
                    route_id=route_id,
                    mode=payload.mode,
                    live=live,
                    trace=trace,
                )
                route_arrivals = [
                    item
                    for item in arrivals_res.arrivals
                    if item.routeNo == route_no or item.routeId == route_id
                ]
                fallback_source = arrivals_res.fallbackSource
                if route_arrivals:
                    first = min(item.arrivalMinutes for item in route_arrivals)
                    source_label = "실시간" if arrivals_res.fallbackSource == FallbackSource.PUBLIC_API else arrivals_res.fallbackSource.value
                    message = f"{stop_name} 기준 {route_no}번 첫 번째 버스는 {source_label} 기준 약 {first}분 뒤 도착 예정이에요."
                else:
                    status = get_service_status_tool(
                        route_no=route_no,
                        arrivals=route_arrivals,
                        trace=trace,
                    )
                    message = f"{stop_name} 기준 {route_no}번은 {status.message}"
            except Exception:
                fallback_source = FallbackSource.ERROR
                message = f"{stop_name} 기준 {route_no}번 도착정보를 가져오지 못했어요."

    elif intent == AgentIntent.SELECT_ARRIVAL:
        if not session.selected_route_no:
            message = "먼저 목적지 경로를 선택해 주세요."
        else:
            session.target_bus_id = _first_plan_arrival_bus_id(session) or session.target_bus_id
            if session.target_bus_id is None and session.last_route_plan is None:
                session.target_bus_id = _default_target_bus_id(session.selected_route_no)
            session.state = GuidanceState.WAITING_FOR_BUS
            message = "선택한 경로로 안내해 드릴게요. 정류장에 도착하면 대기 범위 감지를 시작할게요."

    elif intent == AgentIntent.ASK_CAN_BOARD_CURRENT_BUS:
        if live:
            route_id = session.selected_route_id
            stop_id = session.selected_stop_id
            if not route_id or not stop_id:
                message = "먼저 목적지 경로를 선택해 주세요."
            else:
                try:
                    locations_res = get_bus_locations_tool(
                        route_id=route_id,
                        route_no=session.selected_route_no or "",
                        mode=payload.mode,
                        trace=trace,
                    )
                    buses_at_stop = [l for l in locations_res.locations if l.nodeId == stop_id]
                    context_data = {
                        "beacon_status": session.last_decision or "NO_BEACON",
                        "live_buses_at_current_stop": [b.model_dump(mode="json") for b in buses_at_stop],
                    }
                    dynamic_msg = generate_dynamic_response(
                        intent=intent,
                        utterance=utterance,
                        wake_word=wake_word,
                        context_data=context_data,
                        history=history,
                    )
                    message = dynamic_msg or "아직 타야 할 버스가 오지 않은 것 같아."
                    used_gemini = bool(dynamic_msg)
                    if used_gemini:
                        fallback_source = FallbackSource.PUBLIC_API
                        tts_mode = TtsMode.GEMINI_OPTIONAL
                except Exception:
                    message = "버스 위치 조회를 실패했어요. 비프음이 가까워질 때까지 기다려 주세요."
        else:
            tts_mode = TtsMode.SAFETY_LOCAL
            if session.last_decision == BeaconDecision.TARGET_BUS_NEAR:
                message = "네, 지금 가까이 온 버스가 타야 할 버스예요. 조심해서 탑승해 주세요."
                cue = V3Cue(
                    type=CueType.TARGET_BUS_NEAR,
                    ttsMode=TtsMode.LOCAL_TTS,
                    shouldVibrate=True,
                    shouldBeep=True,
                    message="타야 할 버스가 가까이 왔어요.",
                )
            elif session.last_decision == BeaconDecision.WRONG_BUS_NEAR:
                message = "아니에요. 지금 가까운 버스는 타야 할 버스가 아니에요. 기다려 주세요."
                cue = V3Cue(
                    type=CueType.WRONG_BUS_NEAR,
                    ttsMode=TtsMode.SAFETY_LOCAL,
                    shouldVibrate=True,
                    shouldBeep=True,
                    message="잘못된 버스가 가까이 왔어요.",
                )
                tts_mode = TtsMode.SAFETY_LOCAL
            else:
                message = "아직 타야 할 버스라고 확인되지 않았어요. 비프음이 가까워질 때까지 기다려 주세요."

    elif intent == AgentIntent.REPORT_MISSED_BUS:
        session.state = GuidanceState.WAITING_FOR_BUS
        session.target_bus_id = _next_target_bus_id(session.selected_route_no, session.target_bus_id)
        session.last_decision = None
        session.nearest_beacon = None
        session.target_bus = None
        message = "괜찮아요. 다음 버스를 다시 안내해 드릴게요."

    else:
        contextual_reply = contextual_reply_hint or _contextual_followup_reply(session=session, utterance=utterance)
        if contextual_reply:
            message = contextual_reply
            tts_mode = TtsMode.LOCAL_TTS
            used_gemini = False
            fallback_source = FallbackSource.CACHE if session.selected_plan or session.recommended_plan else FallbackSource.MOCK
        else:
            gemini_reply = generate_optional_reply(
                utterance=utterance,
                wake_word=wake_word,
                history=history,
                pending_question=session.pending_question,
            )
            if gemini_reply:
                message = gemini_reply
                tts_mode = TtsMode.GEMINI_OPTIONAL
                used_gemini = True
                fallback_source = FallbackSource.GEMINI
            else:
                # Gemini를 쓸 수 없을 때도 같은 문장만 앵무새처럼 반복하지 않도록
                # 대화 맥락/세션 상태에 따라 다른 로컬 폴백을 만든다.
                message = _local_smalltalk_fallback(session, utterance)

    return _agent_response(
        trace=trace,
        session=session,
        utterance=utterance,
        intent=intent,
        message=message,
        tts_mode=tts_mode,
        cue=cue,
        used_gemini=used_gemini,
        fallback_source=fallback_source,
        route_plan=route_plan,
    )


def _agent_response(
    *,
    trace: AgentTraceRecorder,
    session: V3SessionRecord,
    utterance: str,
    intent: AgentIntent,
    message: str,
    tts_mode: TtsMode,
    cue: V3Cue,
    used_gemini: bool,
    fallback_source: FallbackSource,
    route_plan: RoutePlanResponse | None,
) -> AgentConverseResponse:
    safety_event = trace.start(
        "SAFETY_FILTER",
        "안내 문장 안전 확인",
        operation="sanitizeAgentReply",
    )
    safe_message = sanitize_agent_reply_tool(message, assistant_name=session.wake_word)
    if safe_message:
        trace.done(safety_event, "추측성 표현과 위험한 방향 안내가 없는지 확인했어.")
    else:
        trace.fail(safety_event, "안전하지 않은 표현을 제거하고 보수적인 안내로 바꿨어.")
        safe_message = "검증된 정보만으로는 지금 안내하기 어려워."
    trace.record(
        "FINAL_RESPONSE",
        "최종 안내 생성 완료",
        "검증된 정보만 사용해 사용자 안내를 만들었어.",
        safe_payload={
            "intent": intent.value,
            "state": session.state.value,
            "usedGemini": used_gemini,
            "fallbackSource": fallback_source.value,
        },
    )
    _append_conversation_turn(
        session,
        utterance=utterance,
        response=safe_message,
        intent=intent.value,
    )
    session.touch()
    return AgentConverseResponse(
        sessionId=session.session_id,
        intent=intent,
        state=session.state,
        message=safe_message,
        ttsMode=tts_mode,
        cue=cue,
        usedGemini=used_gemini,
        fallbackSource=fallback_source,
        routePlan=route_plan,
        trace=trace.to_list(),
        traceId=trace.trace_id,
    )



def _append_conversation_turn(
    session: V3SessionRecord,
    *,
    utterance: str,
    response: str,
    intent: str,
) -> None:
    history = session.conversation_history
    history.append(
        {
            "utterance": utterance,
            "response": response,
            "intent": intent,
            "state": session.state.value,
        }
    )
    if len(history) > 12:
        del history[:-12]


def _contextual_followup_reply(*, session: V3SessionRecord, utterance: str) -> str | None:
    compact = _compact(utterance)
    if not compact:
        return None

    route_question_terms = (
        "무슨경로",
        "어떤경로",
        "현재경로",
        "선택한경로",
        "그경로",
        "경로뭐",
        "경로가뭐",
        "경로알려",
        "어디서타",
        "어디에서타",
        "어디서내",
        "어디에서내",
        "몇번버스",
        "몇번타",
        "노선뭐",
        "버스뭐",
        "추천이유",
        "왜이경로",
        "왜추천",
    )
    destination_question_terms = ("목적지뭐", "어디가는", "어디로가", "어디까지")

    if any(term in compact for term in route_question_terms):
        return _selected_route_context_message(session, utterance=utterance)

    if any(term in compact for term in destination_question_terms):
        if session.selected_destination:
            return f"현재 목적지는 {session.selected_destination}로 잡혀 있어요."
        if session.pending_question:
            return session.pending_question
        return "아직 목적지가 정해지지 않았어요. 장소명이나 주소를 말씀해 주세요."

    if compact in {"뭐", "뭔데", "무슨말", "다시", "다시말해줘", "자세히"}:
        if session.pending_question:
            return session.pending_question
        if session.selected_plan or session.recommended_plan or session.last_route_plan:
            return _selected_route_context_message(session, utterance=utterance)
        if session.conversation_history:
            last = session.conversation_history[-1].get("response")
            if isinstance(last, str) and last:
                return last
    return None


def _selected_route_context_message(session: V3SessionRecord, *, utterance: str) -> str:
    plan = _selected_plan_dict(session)
    if not plan:
        if session.pending_question:
            return session.pending_question
        return "아직 선택된 경로가 없어요. 먼저 목적지를 말씀해 주세요."

    destination = _safe_str(plan.get("destinationName")) or session.selected_destination or "목적지"
    summary = _safe_str(plan.get("summary"))
    instruction = _safe_str(plan.get("boardingInstruction"))
    reason = _safe_str(plan.get("recommendedReason"))
    segments = plan.get("segments")
    first_segment = segments[0] if isinstance(segments, list) and segments and isinstance(segments[0], dict) else None
    if not first_segment:
        return instruction or summary or f"{destination} 경로는 아직 세부 구간을 확인하지 못했어요."

    route_no = _safe_str(first_segment.get("routeNo")) or session.selected_route_no or "확인된 버스"
    board_stop = first_segment.get("boardStop")
    alight_stop = first_segment.get("alightStop")
    board_name = _safe_str(board_stop.get("stopName")) if isinstance(board_stop, dict) else session.selected_stop_name
    alight_name = _safe_str(alight_stop.get("stopName")) if isinstance(alight_stop, dict) else None
    direction = _safe_str(first_segment.get("directionHint"))
    arrival_text = _first_arrival_text(first_segment)

    parts = [f"현재 선택된 경로는 {destination} 방향 {route_no}번이에요."]
    if board_name and alight_name:
        parts.append(f"{board_name}에서 타고 {alight_name}에서 내리는 경로예요.")
    elif board_name:
        parts.append(f"{board_name}에서 타시면 돼요.")
    if direction:
        parts.append(f"승차 방향은 {direction}로 확인됐어요.")
    if arrival_text:
        parts.append(arrival_text)
    elif first_segment.get("arrivalUnknown"):
        service_status = first_segment.get("serviceStatus")
        if isinstance(service_status, dict) and isinstance(service_status.get("message"), str):
            parts.append(service_status["message"])
        else:
            parts.append("실시간 도착정보는 아직 확인되지 않았어요.")
    if reason and any(term in _compact(utterance) for term in {"왜", "추천", "이유"}):
        parts.append(reason)
    elif summary and len(" ".join(parts)) < 120:
        parts.append(summary)
    return " ".join(parts)


def _selected_plan_dict(session: V3SessionRecord) -> dict | None:
    for candidate in (session.selected_plan, session.recommended_plan):
        if isinstance(candidate, dict):
            return candidate
    if isinstance(session.last_route_plan, dict):
        recommended = session.last_route_plan.get("recommendedPlan")
        if isinstance(recommended, dict):
            return recommended
    return None


def _safe_str(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _first_arrival_text(segment: dict) -> str | None:
    arrivals = segment.get("arrivals")
    if not isinstance(arrivals, list) or not arrivals:
        return None
    first = arrivals[0]
    if not isinstance(first, dict):
        return None
    minutes = first.get("arrivalMinutes")
    if isinstance(minutes, int):
        return f"첫 번째 버스는 약 {minutes}분 뒤 도착 예정이에요."
    return None

def _conversation_history_for_gemini(session: V3SessionRecord) -> list[dict]:
    """세션의 대화 기록을 Gemini contents용 user/model 턴 목록으로 변환한다.

    대화창을 초기화(세션 리셋)하기 전까지 누적된 맥락을 에이전트가 기억하도록,
    최근 turn들을 (오래된 것부터) user→model 순서로 펼쳐서 반환한다.
    """
    history_raw = getattr(session, "conversation_history", None)
    if not isinstance(history_raw, list) or not history_raw:
        return []
    turns: list[dict] = []
    for entry in history_raw[-_MAX_HISTORY_TURNS:]:
        if not isinstance(entry, dict):
            continue
        utterance = entry.get("utterance")
        response = entry.get("response")
        if isinstance(utterance, str) and utterance.strip():
            turns.append({"role": "user", "text": utterance.strip()[:_MAX_HISTORY_CHARS]})
        if isinstance(response, str) and response.strip():
            turns.append({"role": "model", "text": response.strip()[:_MAX_HISTORY_CHARS]})
    return turns


def _local_smalltalk_fallback(session: V3SessionRecord, utterance: str) -> str:
    """Gemini를 쓸 수 없을 때의 로컬 잡담 폴백.

    같은 문장만 반복하지 않도록 세션 상태(선택된 경로/목적지/대기 질문)에 따라
    맥락 있는 안내로 바꾼다.
    """
    if session.pending_question:
        return session.pending_question
    if session.selected_route_no and session.selected_destination:
        return (
            f"지금은 {session.selected_destination} 방향 {session.selected_route_no}번 안내를 잡아두고 있어요. "
            "도착정보나 다른 목적지가 필요하면 말씀해 주세요."
        )
    if session.selected_destination:
        return f"현재 목적지는 {session.selected_destination}로 잡혀 있어요. 경로가 필요하면 '몇 번 버스 타야 돼요?'처럼 물어봐 주세요."
    return "어디로 갈지 장소나 정류장 이름을 말해주면 버스 경로를 찾아줄게."


def _infer_destination_confirmation(
    *,
    heard_text: str,
    origin_lat: float | None,
    origin_lng: float | None,
    live: bool,
    mode: str | None,
    trace: AgentTraceRecorder,
) -> RoutePlanResponse | None:
    """API에 없는 목적지를 Gemini로 청주 내 후보로 추론하고, 우리 API로 검증해서
    실재가 확인되면 '혹시 X 맞을까?' NEEDS_CONFIRMATION RoutePlan을 만든다.

    검증을 통과하지 못하면(추론 실패 또는 우리 API에 없음) None을 반환해 원래의
    NOT_FOUND를 유지한다(임의 지명을 지어내 묻지 않는다).
    """
    try:
        guess = infer_cheongju_destination(
            heard_text=heard_text,
            known_destinations=cheongju_route_catalog.DESTINATIONS,
        )
    except Exception:
        guess = None
    if not guess or _compact(guess) == _compact(heard_text):
        return None

    # 추론 결과를 우리 API(resolver/planner)로 검증한다.
    verify = _plan_route(
        heard_text=guess,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
        live=live,
        mode=mode,
        trace=trace,
    )
    if verify.status == RoutePlanStatus.NOT_FOUND or verify.destination is None:
        return None
    top = verify.destination.topCandidate
    if top is None or top.latitude is None or top.longitude is None:
        return None

    # 표기 차이만 있는 명백한 일치(예: "충북대 병원" → "충북대학교병원")는
    # 되묻지 않고 검증된 경로를 그대로 안내한다.
    if _is_obvious_destination_match(heard_text, top.name):
        trace.record(
            "DESTINATION_INFERENCE",
            "목적지 추론·검증 완료(자동 확정)",
            "들린 목적지가 검증된 후보와 명백히 일치해 확인 질문 없이 바로 안내해.",
            safe_payload={
                "heardText": heard_text,
                "inferred": guess,
                "verified": top.name,
            },
        )
        return verify

    question = f"혹시 {top.name} 맞을까요?"
    trace.record(
        "DESTINATION_INFERENCE",
        "목적지 추론·검증 완료",
        "들린 목적지를 청주 내 후보로 추론하고 API로 검증한 뒤 확인 질문을 만들었어.",
        safe_payload={"heardText": heard_text, "inferred": guess, "verified": top.name},
    )
    return verify.model_copy(
        update={
            "status": RoutePlanStatus.NEEDS_CONFIRMATION,
            "readiness": RoutePlanReadiness.NEEDS_CONFIRMATION,
            "recommendedPlan": None,
            "plans": [],
            "alternatives": [],
            "agentMessage": question,
            "question": question,
        }
    )


def _handle_route_request(
    *,
    session: V3SessionRecord,
    payload: AgentConverseRequest,
    intent: AgentIntent,
    nlp_destination: str | None,
    live: bool,
    trace: AgentTraceRecorder,
    history: list[dict] | None = None,
) -> tuple[RoutePlanResponse | None, str, TtsMode, bool, FallbackSource]:
    explicit_destination = _extract_destination(payload.utterance) or nlp_destination
    if explicit_destination:
        previous_destination = session.selected_destination
        _clear_selected_route_context(session)
        if previous_destination:
            trace.record(
                "SESSION_ROUTE_REPLACE",
                "이전 경로 교체 완료",
                "새 목적지가 감지되어 이전 경로를 교체했어.",
                safe_payload={
                    "previousDestination": previous_destination,
                    "newDestination": explicit_destination,
                },
            )
    destination = explicit_destination or session.selected_destination

    # 위치가 있으면 새 RoutePlan 기반으로 임의 장소/주소/정류장명을 처리한다.
    if payload.originLat is not None and payload.originLng is not None:
        heard_text = nlp_destination or _generic_destination_text(payload.utterance) or destination or payload.utterance
        route_plan = _plan_route(
            heard_text=heard_text,
            origin_lat=payload.originLat,
            origin_lng=payload.originLng,
            live=live,
            mode=payload.mode,
            trace=trace,
        )
        # 우리 API에 안 나오는 목적지면, Gemini가 청주 내 비슷한 곳을 추론하고
        # 그 추론을 다시 우리 API로 검증한 뒤에만 "혹시 X 맞을까?"로 되묻는다.
        if route_plan.status == RoutePlanStatus.NOT_FOUND:
            inferred = _infer_destination_confirmation(
                heard_text=heard_text,
                origin_lat=payload.originLat,
                origin_lng=payload.originLng,
                live=live,
                mode=payload.mode,
                trace=trace,
            )
            if inferred is not None:
                route_plan = inferred
        return _route_plan_response_tuple(
            session=session,
            route_plan=route_plan,
            utterance=payload.utterance,
            wake_word=payload.wakeWord,
            origin_lat=payload.originLat,
            origin_lng=payload.originLng,
            trace=trace,
            history=history,
        )

    # 위치가 없으면 예전 고정 카탈로그 문장으로 승차 정류장을 꾸며내지 않는다.
    # 특히 "충북대병원" 같은 목적지 alias가 destination stop을 boarding stop처럼
    # 말하는 회귀를 만들 수 있으므로, RoutePlan의 위치 필요 응답만 사용한다.
    heard_text = nlp_destination or _generic_destination_text(payload.utterance) or destination or payload.utterance
    route_plan = _plan_route(
        heard_text=heard_text,
        origin_lat=None,
        origin_lng=None,
        live=live,
        mode=payload.mode,
        trace=trace,
    )
    return _route_plan_response_tuple(
        session=session,
        route_plan=route_plan,
        utterance=payload.utterance,
        wake_word=payload.wakeWord,
        origin_lat=None,
        origin_lng=None,
        trace=trace,
        history=history,
    )


def _route_plan_response_tuple(
    *,
    session: V3SessionRecord,
    route_plan: RoutePlanResponse,
    utterance: str,
    wake_word: str,
    origin_lat: float | None,
    origin_lng: float | None,
    trace: AgentTraceRecorder,
    history: list[dict] | None = None,
) -> tuple[RoutePlanResponse, str, TtsMode, bool, FallbackSource]:
    route_plan = verify_route_tool(route_plan)
    session.origin_location = (
        {"latitude": origin_lat, "longitude": origin_lng}
        if origin_lat is not None and origin_lng is not None
        else session.origin_location
    )
    if route_plan.status == RoutePlanStatus.RESOLVED and route_plan.recommendedPlan is not None:
        _apply_route_plan(session, route_plan)
        _clear_pending(session)
    elif route_plan.status in {RoutePlanStatus.NEEDS_CONFIRMATION, RoutePlanStatus.NEEDS_CHOICE}:
        _store_pending(session, route_plan, origin_lat=origin_lat, origin_lng=origin_lng)
    else:
        _clear_pending(session)

    trace.skip(
        "GEMINI_REPLY_GENERATION",
        "자연어 안내 생성",
        "검증된 경로를 10초 안에 안내하기 위해 규칙 기반 문장을 즉시 사용했어.",
        provider="Gemini",
        operation="generateGroundedReply",
    )
    return route_plan, _deterministic_route_plan_message(route_plan), TtsMode.SAFETY_LOCAL, False, route_plan.fallbackSource


def _try_answer_pending_destination(
    session: V3SessionRecord,
    payload: AgentConverseRequest,
    *,
    live: bool,
    trace: AgentTraceRecorder,
) -> AgentConverseResponse | None:
    if not session.pending_resolution_status:
        return None

    text = payload.utterance.strip()
    query: str | None = None
    status = session.pending_resolution_status

    if status == RoutePlanStatus.NEEDS_CONFIRMATION.value:
        if _is_negative(text):
            _clear_pending(session)
            trace.record(
                "PENDING_CHOICE_MATCH",
                "목적지 확인 취소 완료",
                "후보 확인을 취소하고 새 목적지를 기다리고 있어.",
            )
            return _agent_response(
                trace=trace,
                session=session,
                utterance=text,
                intent=AgentIntent.CORRECT_DESTINATION,
                message="알겠어요. 목적지를 다시 말씀해 주세요.",
                tts_mode=TtsMode.LOCAL_TTS,
                cue=V3Cue(),
                used_gemini=False,
                fallback_source=FallbackSource.MOCK,
                route_plan=None,
            )
        if _is_affirmative(text) and session.pending_top_candidate_name:
            query = session.pending_top_candidate_name
        elif session.pending_top_candidate_name and _compact(session.pending_top_candidate_name) in _compact(text):
            query = session.pending_top_candidate_name

    elif status == RoutePlanStatus.NEEDS_CHOICE.value:
        match = match_pending_choice_tool(text, session.pending_choice_names)
        query = match.candidate if match.matched else None

    if query is None:
        trace.record(
            "PENDING_CHOICE_MATCH",
            "목적지 후보 선택 대기",
            "말한 내용에서 후보를 확정하지 못해 다시 물어봤어.",
            status="FAILED",
            safe_payload={"candidateCount": len(session.pending_choice_names)},
        )
        return _agent_response(
            trace=trace,
            session=session,
            utterance=text,
            intent=AgentIntent.FIND_ROUTE,
            message=session.pending_question or "어느 목적지인지 한 번만 더 말씀해 주세요.",
            tts_mode=TtsMode.LOCAL_TTS,
            cue=V3Cue(),
            used_gemini=False,
            fallback_source=FallbackSource.MOCK,
            route_plan=None,
        )

    trace.record(
        "PENDING_CHOICE_MATCH",
        "목적지 후보 선택 완료",
        f"{query} 후보를 선택했어요.",
        safe_payload={"selectedCandidate": query},
    )
    origin_lat = payload.originLat if payload.originLat is not None else session.pending_origin_lat
    origin_lng = payload.originLng if payload.originLng is not None else session.pending_origin_lng
    route_plan = _plan_route(
        heard_text=query,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
        live=live,
        mode=payload.mode,
        trace=trace,
    )
    route_plan, message, tts_mode, used_gemini, fallback_source = _route_plan_response_tuple(
        session=session,
        route_plan=route_plan,
        utterance=payload.utterance,
        wake_word=payload.wakeWord,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
        trace=trace,
        history=_conversation_history_for_gemini(session),
    )
    return _agent_response(
        trace=trace,
        session=session,
        utterance=text,
        intent=AgentIntent.FIND_ROUTE,
        message=message,
        tts_mode=tts_mode,
        cue=V3Cue(),
        used_gemini=used_gemini,
        fallback_source=fallback_source,
        route_plan=route_plan,
    )


def _plan_route(
    *,
    heard_text: str,
    origin_lat: float | None,
    origin_lng: float | None,
    live: bool,
    mode: str | None,
    trace: AgentTraceRecorder,
) -> RoutePlanResponse:
    return plan_transit_route_tool(
        destination_text=heard_text,
        origin_lat=origin_lat,
        origin_lng=origin_lng,
        mode=mode,
        trace=trace,
    )


def _apply_route_plan(session: V3SessionRecord, route_plan: RoutePlanResponse) -> None:
    plan = route_plan.recommendedPlan
    if plan is None or not plan.segments:
        return
    segment = plan.segments[0]
    session.selected_destination = plan.destinationName
    session.selected_route_no = segment.routeNo
    session.selected_route_id = segment.routeId
    session.selected_stop_id = segment.boardStop.stopId
    session.selected_stop_name = segment.boardStop.stopName
    session.selected_plan_id = plan.planId
    session.nearby_boarding_stops = [
        item.model_dump(mode="json") for item in route_plan.destination.originStops
    ]
    session.nearby_alighting_stops = [
        item.model_dump(mode="json") for item in route_plan.destination.destinationStops
    ]
    session.recommended_plan = plan.model_dump(mode="json")
    session.alternative_plans = [item.model_dump(mode="json") for item in route_plan.alternatives]
    session.selected_plan = session.recommended_plan
    session.current_leg_index = 0
    session.target_bus_id = None
    session.last_decision = None
    session.nearest_beacon = None
    session.target_bus = None
    session.last_route_plan = route_plan.model_dump(mode="json")
    session.state = GuidanceState.ROUTE_RECOMMENDED


def _store_pending(
    session: V3SessionRecord,
    route_plan: RoutePlanResponse,
    *,
    origin_lat: float | None,
    origin_lng: float | None,
) -> None:
    destination = route_plan.destination
    session.pending_question = route_plan.question or destination.question
    session.pending_resolution_status = route_plan.status.value
    session.pending_heard_text = route_plan.heardText
    session.pending_top_candidate_name = destination.topCandidate.name if destination.topCandidate else None
    session.pending_choice_names = [item.name for item in destination.candidates]
    session.pending_origin_lat = origin_lat
    session.pending_origin_lng = origin_lng
    session.nearby_boarding_stops = [
        item.model_dump(mode="json") for item in destination.originStops
    ]
    session.nearby_alighting_stops = [
        item.model_dump(mode="json") for item in destination.destinationStops
    ]
    session.origin_location = (
        {"latitude": origin_lat, "longitude": origin_lng}
        if origin_lat is not None and origin_lng is not None
        else None
    )
    session.last_route_plan = route_plan.model_dump(mode="json")


def _clear_pending(session: V3SessionRecord) -> None:
    session.pending_question = None
    session.pending_resolution_status = None
    session.pending_heard_text = None
    session.pending_top_candidate_name = None
    session.pending_choice_names = []
    session.pending_origin_lat = None
    session.pending_origin_lng = None


def _clear_selected_route_context(session: V3SessionRecord) -> None:
    session.selected_destination = None
    session.selected_route_no = None
    session.selected_route_id = None
    session.selected_stop_id = None
    session.selected_stop_name = None
    session.target_bus_id = None
    session.selected_plan_id = None
    session.nearby_boarding_stops = []
    session.nearby_alighting_stops = []
    session.recommended_plan = None
    session.alternative_plans = []
    session.selected_plan = None
    session.current_leg_index = 0
    session.last_route_plan = None
    session.last_decision = None
    session.nearest_beacon = None
    session.target_bus = None
    session.state = GuidanceState.IDLE
    _clear_pending(session)


def _deterministic_route_plan_message(route_plan: RoutePlanResponse) -> str:
    if route_plan.status != RoutePlanStatus.RESOLVED or route_plan.recommendedPlan is None:
        return route_plan.question or route_plan.destination.question or "목적지를 다시 말씀해 주세요."
    plan = route_plan.recommendedPlan
    if not plan.segments:
        return plan.boardingInstruction or route_plan.question or "승차 경로를 찾지 못했어요."
    first = plan.segments[0]
    message = _segment_guidance_sentence(first)
    if plan.verificationStatus.value in {"ODSAY_ONLY", "PARTIAL"}:
        message += " 정류장에서는 전광판이나 버스 번호를 한 번 더 확인해 주세요."
    if not first.directionHint:
        message += " 정류장 방향 정보는 확실히 확인하지 못했어요. 정류장 표지판에서 노선 방향을 한 번 더 확인해 주세요."
    if any("ODsay unavailable" in warning for warning in route_plan.warnings):
        message = f"ODsay 경로탐색은 지금 사용할 수 없어서, 청주 버스 공공데이터 기준으로 경로를 계산했어요. {message}"
    if plan.type.value == "ONE_TRANSFER" and len(plan.segments) >= 2:
        second = plan.segments[1]
        message += f" 이어서 {second.boardStop.stopName}에서 {second.routeNo}번으로 갈아타고 {second.alightStop.stopName}에서 내려."
    return message


def _segment_guidance_sentence(segment) -> str:
    board = segment.boardStop.stopName
    alight = segment.alightStop.stopName
    direction = segment.directionHint or segment.boardStop.directionHint
    message = f"{board}에서 {segment.routeNo}번을 타고 {alight}에서 내려."
    if direction:
        message += f" 승차 방향은 {direction}이에요."
    first_arrival = min((arrival.arrivalMinutes for arrival in segment.arrivals), default=None)
    if first_arrival is not None:
        message += f" 지금 기준 첫 차는 약 {first_arrival}분 뒤 도착 예정이에요."
    elif segment.serviceStatus is not None and segment.serviceStatus.message:
        message += f" {segment.serviceStatus.message}"
    elif segment.arrivalUnknown:
        message += " 실시간 도착정보는 아직 확인하지 못했어요."
    return message


def _first_plan_arrival_bus_id(session: V3SessionRecord) -> str | None:
    plan = (session.last_route_plan or {}).get("recommendedPlan") if isinstance(session.last_route_plan, dict) else None
    if not isinstance(plan, dict):
        return None
    segments = plan.get("segments")
    if not isinstance(segments, list) or not segments:
        return None
    first = segments[0]
    arrivals = first.get("arrivals") if isinstance(first, dict) else None
    if not isinstance(arrivals, list) or not arrivals:
        return None
    bus_id = arrivals[0].get("busId") if isinstance(arrivals[0], dict) else None
    return bus_id if isinstance(bus_id, str) and bus_id else None


def _arrivals_from_last_route_plan(session: V3SessionRecord, *, route_no: str) -> list[dict]:
    plan = (session.last_route_plan or {}).get("recommendedPlan") if isinstance(session.last_route_plan, dict) else None
    if not isinstance(plan, dict):
        return []
    segments = plan.get("segments")
    if not isinstance(segments, list):
        return []
    out: list[dict] = []
    for segment in segments:
        if not isinstance(segment, dict) or segment.get("routeNo") != route_no:
            continue
        arrivals = segment.get("arrivals")
        if isinstance(arrivals, list):
            out.extend(item for item in arrivals if isinstance(item, dict))
    return out


def _selected_arrival_target(session: V3SessionRecord) -> tuple[str, str | None, str, str] | None:
    plan = session.selected_plan or session.recommended_plan
    if isinstance(plan, dict):
        segments = plan.get("segments")
        if isinstance(segments, list) and segments and isinstance(segments[0], dict):
            segment = segments[0]
            board_stop = segment.get("boardStop")
            if isinstance(board_stop, dict):
                route_no = segment.get("routeNo")
                stop_id = board_stop.get("stopId")
                stop_name = board_stop.get("stopName")
                if isinstance(route_no, str) and isinstance(stop_id, str) and isinstance(stop_name, str):
                    route_id = segment.get("routeId")
                    return route_no, route_id if isinstance(route_id, str) else None, stop_id, stop_name
    if session.selected_route_no and session.selected_stop_id and session.selected_stop_name:
        return session.selected_route_no, session.selected_route_id, session.selected_stop_id, session.selected_stop_name
    return None


def _detect_intent(utterance: str, wake_word: str) -> AgentIntent:
    return classify_agent_intent(utterance, wake_word=wake_word).intent


def _is_explicit_new_route_request(utterance: str, wake_word: str) -> bool:
    return _detect_intent(utterance, wake_word) in {
        AgentIntent.FIND_ROUTE,
        AgentIntent.CHANGE_DESTINATION,
        AgentIntent.CORRECT_DESTINATION,
    } and _generic_destination_text(utterance) is not None


def _compact(text: str) -> str:
    return "".join(character for character in text if character.isalnum())


def _normalize_place(text: str) -> str:
    """장소명을 느슨하게 정규화한다(표기 차이 흡수용).

    예: "충북대 병원" ↔ "충북대학교병원" 을 같은 키로 만든다.
    """
    compact = _compact(text)
    return compact.replace("대학교", "대").replace("학교", "")


def _is_obvious_destination_match(heard: str, name: str) -> bool:
    """들린 목적지와 (API로 검증된) 후보가 명백히 같은 곳이면 True.

    이 경우 "혹시 X 맞을까?" 되묻지 않고 바로 안내한다. 검증 단계에서 이미
    실재가 확인된 후보이므로, 표기 차이만 있는 명백한 일치는 확인을 생략한다.
    """
    a = _normalize_place(heard)
    b = _normalize_place(name)
    if len(a) < 3 or len(b) < 3:
        return False
    return a == b or a in b or b in a


def _extract_destination(utterance: str) -> str | None:
    compact = utterance.replace(" ", "")
    if "아니라" in utterance:
        return _extract_destination(utterance.split("아니라", 1)[1])
    for alias, canonical in _DESTINATION_ALIASES:
        if alias.replace(" ", "") in compact:
            return canonical
    cleaned = _generic_destination_text(utterance)
    return cleaned if cleaned else None


def _generic_destination_text(utterance: str) -> str | None:
    return normalize_user_utterance(utterance).destination_candidate_text


def _is_affirmative(text: str) -> bool:
    compact = _compact(text)
    return compact in {"응", "어", "맞아", "맞음", "그래", "ㅇㅇ", "네", "예", "맞습니다"} or "맞아" in text or "그거" in text


def _is_negative(text: str) -> bool:
    compact = _compact(text)
    return compact in {"아니", "아니야", "ㄴㄴ", "노", "no"} or "아니" in text


def _choice_index(text: str) -> int | None:
    match = match_pending_choice_tool(text, ["0", "1", "2"])
    return match.candidate_index if match.matched else None


def _match_choice_name(text: str, names: list[str]) -> str | None:
    match = match_pending_choice_tool(text, names)
    return match.candidate if match.matched else None


def _default_target_bus_id(route_no: str | None) -> str:
    if route_no == "823":
        return "BUS_823"
    if route_no == "862":
        return "BUS_862"
    return "BUS_2"


def _next_target_bus_id(route_no: str | None, current_bus_id: str | None) -> str:
    if route_no == "823":
        return "BUS_823_NEXT"
    if route_no == "862":
        return "BUS_862_NEXT"
    if current_bus_id == "BUS_2":
        return "BUS_502_NEXT"
    return "BUS_502_NEXT"
