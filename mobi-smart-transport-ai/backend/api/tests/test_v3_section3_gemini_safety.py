import base64

import httpx

from app.services import v3_gemini_service


def test_route_plan_reply_rejects_vision_required_crossing_claim(monkeypatch) -> None:
    captured = {}

    def fake_generate(**kwargs):
        captured.update(kwargs)
        return "도로를 건너 오른쪽 정류장에서 862번을 타면 돼."

    monkeypatch.setattr(v3_gemini_service, "_generate", fake_generate)

    reply = v3_gemini_service.generate_route_plan_reply(
        route_plan={"status": "RESOLVED", "recommendedPlan": {"segments": []}},
        utterance="상당산성 가고 싶어",
        wake_word="자비스",
    )

    assert reply is None
    assert captured["thinking_budget"] == 128
    assert "RoutePlan JSON" in captured["system_instruction"]
    assert "새 버스번호" in captured["system_instruction"]


def test_dynamic_reply_rejects_vision_required_side_claim(monkeypatch) -> None:
    monkeypatch.setattr(
        v3_gemini_service,
        "_generate",
        lambda **_: "건너편 정류장에서 기다리면 돼.",
    )

    reply = v3_gemini_service.generate_dynamic_response(
        intent="QUERY_ARRIVAL",
        utterance="언제 와?",
        wake_word="자비스",
        context_data={"arrivals": []},
    )

    assert reply is None


def test_missing_gemini_key_keeps_route_plan_reply_optional(monkeypatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)

    reply = v3_gemini_service.generate_route_plan_reply(
        route_plan={"status": "NO_ROUTE", "question": "경로를 찾지 못했어."},
        utterance="어떻게 가?",
        wake_word="자비스",
    )

    assert reply is None


def test_route_plan_reply_falls_back_to_flash_when_pro_is_unavailable(monkeypatch) -> None:
    models = []

    def fake_generate(**kwargs):
        models.append(kwargs["model"])
        return None if len(models) == 1 else "확인된 RoutePlan 기준으로 안내할게."

    monkeypatch.setattr(v3_gemini_service, "_generate", fake_generate)

    reply = v3_gemini_service.generate_route_plan_reply(
        route_plan={"status": "RESOLVED", "recommendedPlan": {"segments": []}},
        utterance="상당산성 가고 싶어",
        wake_word="자비스",
    )

    assert reply == "확인된 RoutePlan 기준으로 안내할게."
    assert models == ["gemini-2.5-pro", "gemini-2.5-flash"]


def test_route_plan_reply_sends_compact_verified_payload_to_gemini(monkeypatch) -> None:
    captured = {}

    def fake_generate(**kwargs):
        captured.update(kwargs)
        return "확인된 경로만 안내할게."

    monkeypatch.setattr(v3_gemini_service, "_generate", fake_generate)

    v3_gemini_service.generate_route_plan_reply(
        route_plan={
            "status": "RESOLVED",
            "rawProviderEvidence": {"large": "provider payload"},
            "alternatives": [{"planId": "alt"}],
            "recommendedPlan": {
                "planSource": "ODSAY_ENRICHED",
                "verificationStatus": "VERIFIED_WITH_TAGO",
                "summary": "요약",
                "boardingInstruction": "승차 안내",
                "warnings": [],
                "rawProviderEvidence": {"large": "candidate evidence"},
                "segments": [
                    {"routeNo": "509", "routeId": "CJB-509", "arrivals": [{"arrivalMinutes": 3}]},
                    {"routeNo": "862", "routeId": "CJB-862", "arrivals": [{"arrivalMinutes": 8}]},
                ],
            },
        },
        utterance="상당산성 가고 싶어",
        wake_word="자비스",
    )

    prompt = captured["prompt"]
    assert "rawProviderEvidence" not in prompt
    assert "alternatives" not in prompt
    assert '"arrivalMinutes": 3' in prompt
    assert '"arrivalMinutes": 8' not in prompt


def test_gemini_reply_removes_mobi_user_address_but_keeps_self_introduction() -> None:
    assert v3_gemini_service._without_vision_claims("그래, 모비야. 내가 안내해줄게.") == "내가 안내해줄게."
    assert (
        v3_gemini_service._without_vision_claims("안녕, 나는 모비야. 내 말 잘 들려?")
        == "안녕, 나는 모비야. 내 말 잘 들려?"
    )


def test_tts_falls_back_from_pro_to_flash(monkeypatch) -> None:
    models = []

    class FakeResponse:
        def __init__(self, *, ok: bool) -> None:
            self.ok = ok

        def raise_for_status(self) -> None:
            if not self.ok:
                raise httpx.HTTPError("quota exceeded")

        def json(self) -> dict:
            return {
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {
                                    "inlineData": {
                                        "data": base64.b64encode(b"\x00\x00").decode("ascii"),
                                    }
                                }
                            ]
                        }
                    }
                ]
            }

    def fake_post(endpoint, **_):
        model = endpoint.split("/models/", 1)[1].split(":", 1)[0]
        models.append(model)
        return FakeResponse(ok=model == "gemini-3.1-flash-tts-preview")

    monkeypatch.setenv("GEMINI_API_KEY", "test-key")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_TTS_MODEL", raising=False)
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)

    audio = v3_gemini_service.synthesize_tts_wav(text="안녕")

    assert audio is not None
    assert audio.startswith(b"RIFF")
    assert models == ["gemini-2.5-pro-preview-tts", "gemini-3.1-flash-tts-preview"]


class _ChatAudioResponse:
    def __init__(self, transcript: str, audio_bytes: bytes) -> None:
        self._transcript = transcript
        self._audio = audio_bytes

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return {
            "choices": [
                {
                    "message": {
                        "audio": {
                            "data": base64.b64encode(self._audio).decode("ascii"),
                            "transcript": self._transcript,
                        }
                    }
                }
            ]
        }


class _SpeechResponse:
    def __init__(self, content: bytes) -> None:
        self.content = content

    def raise_for_status(self) -> None:
        return None


class _GeminiTtsResponse:
    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return {
            "candidates": [
                {"content": {"parts": [{"inlineData": {"data": base64.b64encode(b"\x00\x00").decode("ascii")}}]}}
            ]
        }


def test_synthesize_tts_gpt_audio_chat_path(monkeypatch):
    captured: dict = {}

    def fake_post(endpoint, **kwargs):
        captured["endpoint"] = endpoint
        captured["json"] = kwargs.get("json")
        return _ChatAudioResponse("안녕하세요 모비입니다", b"RIFFchat")

    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.delenv("OPENAI_TTS_MODEL", raising=False)
    monkeypatch.delenv("OPENAI_TTS_VOICE", raising=False)
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)

    audio = v3_gemini_service.synthesize_tts_wav(text="안녕하세요 모비입니다")

    assert audio == b"RIFFchat"
    assert captured["endpoint"] == "https://api.openai.com/v1/chat/completions"
    assert captured["json"]["model"] == "gpt-audio"
    assert captured["json"]["audio"]["voice"] == "marin"


def test_synthesize_tts_gpt_audio_paraphrase_falls_back_to_speech(monkeypatch):
    calls: list[str] = []

    def fake_post(endpoint, **kwargs):
        calls.append(endpoint)
        if endpoint.endswith("/chat/completions"):
            return _ChatAudioResponse("네 알겠습니다 다른 안내를 드릴게요", b"RIFFchat")
        return _SpeechResponse(b"RIFFspeech")

    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.delenv("OPENAI_TTS_MODEL", raising=False)
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)

    audio = v3_gemini_service.synthesize_tts_wav(text="충북대학교병원으로 가는 502번 버스를 안내합니다")

    assert audio == b"RIFFspeech"
    assert calls == [
        "https://api.openai.com/v1/chat/completions",
        "https://api.openai.com/v1/audio/speech",
    ]


def test_synthesize_tts_pure_model_uses_speech_endpoint(monkeypatch):
    captured: dict = {}

    def fake_post(endpoint, **kwargs):
        captured["endpoint"] = endpoint
        captured["json"] = kwargs.get("json")
        return _SpeechResponse(b"RIFFspeech")

    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("OPENAI_TTS_MODEL", "gpt-4o-mini-tts")
    monkeypatch.delenv("OPENAI_TTS_VOICE", raising=False)
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)

    audio = v3_gemini_service.synthesize_tts_wav(text="안녕")

    assert audio == b"RIFFspeech"
    assert captured["endpoint"] == "https://api.openai.com/v1/audio/speech"
    assert captured["json"]["model"] == "gpt-4o-mini-tts"


def test_synthesize_tts_realtime_model_uses_websocket_path(monkeypatch):
    captured: dict = {}

    def fake_realtime(*, text, model, voice, api_key):
        captured["model"] = model
        captured["voice"] = voice
        return b"RIFFrealtime"

    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("OPENAI_TTS_MODEL", "gpt-realtime-2")
    monkeypatch.setenv("OPENAI_TTS_VOICE", "marin")
    monkeypatch.setattr(v3_gemini_service, "_openai_realtime_wav", fake_realtime)

    audio = v3_gemini_service.synthesize_tts_wav(text="안녕")

    assert audio == b"RIFFrealtime"
    assert captured == {"model": "gpt-realtime-2", "voice": "marin"}


def test_synthesize_tts_realtime_failure_falls_back_to_speech(monkeypatch):
    def fake_realtime(*, text, model, voice, api_key):
        return None

    def fake_post(endpoint, **kwargs):
        assert endpoint == "https://api.openai.com/v1/audio/speech"
        assert kwargs.get("json", {}).get("model") == "gpt-4o-mini-tts"
        return _SpeechResponse(b"RIFFspeech")

    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("OPENAI_TTS_MODEL", "gpt-realtime-2")
    monkeypatch.setattr(v3_gemini_service, "_openai_realtime_wav", fake_realtime)
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)

    audio = v3_gemini_service.synthesize_tts_wav(text="안녕")

    assert audio == b"RIFFspeech"


def test_synthesize_tts_provider_gemini_skips_openai(monkeypatch):
    endpoints: list[str] = []

    def fake_post(endpoint, **kwargs):
        endpoints.append(endpoint)
        return _GeminiTtsResponse()

    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("GEMINI_API_KEY", "test-gemini-key")
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)

    audio = v3_gemini_service.synthesize_tts_wav(text="안녕", provider="gemini")

    assert audio is not None and audio.startswith(b"RIFF")
    assert all("openai.com" not in endpoint for endpoint in endpoints)


def test_synthesize_tts_provider_openai_does_not_fall_back_to_gemini(monkeypatch):
    endpoints: list[str] = []

    def fake_post(endpoint, **kwargs):
        endpoints.append(endpoint)
        raise v3_gemini_service.httpx.HTTPError("boom")

    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("GEMINI_API_KEY", "test-gemini-key")
    monkeypatch.delenv("OPENAI_TTS_MODEL", raising=False)
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)

    audio = v3_gemini_service.synthesize_tts_wav(text="안녕", provider="openai")

    assert audio is None
    assert all("generativelanguage" not in endpoint for endpoint in endpoints)


class _OpenAIChatResponse:
    def __init__(self, content: str) -> None:
        self._content = content

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return {"choices": [{"message": {"content": self._content}}]}


def test_generate_nlu_openai_provider_uses_chat_completions(monkeypatch):
    def fake_post(endpoint, **kwargs):
        assert "generativelanguage" not in endpoint
        assert endpoint == "https://api.openai.com/v1/chat/completions"
        assert kwargs["json"]["model"] == "gpt-4.1-mini"
        return _OpenAIChatResponse("분류결과")

    monkeypatch.setenv("OPENAI_API_KEY", "k")
    monkeypatch.delenv("OPENAI_NLU_MODEL", raising=False)
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)
    v3_gemini_service.set_nlu_provider("openai")
    try:
        out = v3_gemini_service._generate(
            model="gemini-x", system_instruction="s", prompt="p", max_output_tokens=20
        )
    finally:
        v3_gemini_service.set_nlu_provider("auto")
    assert out == "분류결과"


def test_generate_nlu_auto_falls_back_to_openai_when_gemini_fails(monkeypatch):
    calls: list[str] = []

    def fake_post(endpoint, **kwargs):
        calls.append(endpoint)
        if "generativelanguage" in endpoint:
            raise v3_gemini_service.httpx.HTTPError("boom")
        return _OpenAIChatResponse("폴백응답")

    monkeypatch.setenv("OPENAI_API_KEY", "k")
    monkeypatch.setenv("GEMINI_API_KEY", "g")
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)
    v3_gemini_service.set_nlu_provider("auto")
    try:
        out = v3_gemini_service._generate(
            model="gemini-x", system_instruction="s", prompt="p", max_output_tokens=20
        )
    finally:
        v3_gemini_service.set_nlu_provider("auto")
    assert out == "폴백응답"
    assert any("generativelanguage" in c for c in calls)
    assert any("openai.com" in c for c in calls)


def test_generate_nlu_gemini_only_never_calls_openai(monkeypatch):
    def fake_post(endpoint, **kwargs):
        assert "openai.com" not in endpoint
        raise v3_gemini_service.httpx.HTTPError("boom")

    monkeypatch.setenv("OPENAI_API_KEY", "k")
    monkeypatch.setenv("GEMINI_API_KEY", "g")
    monkeypatch.setattr(v3_gemini_service.httpx, "post", fake_post)
    v3_gemini_service.set_nlu_provider("gemini")
    try:
        out = v3_gemini_service._generate(
            model="gemini-x", system_instruction="s", prompt="p", max_output_tokens=20
        )
    finally:
        v3_gemini_service.set_nlu_provider("auto")
    assert out is None


def test_synthesize_tts_model_override_beats_env(monkeypatch):
    captured: dict = {}

    def fake_realtime(*, text, model, voice, api_key):
        captured["model"] = model
        return b"RIFFrt"

    monkeypatch.setenv("OPENAI_API_KEY", "k")
    monkeypatch.setenv("OPENAI_TTS_MODEL", "gpt-audio")
    monkeypatch.setattr(v3_gemini_service, "_openai_realtime_wav", fake_realtime)

    audio = v3_gemini_service.synthesize_tts_wav(
        text="안녕", provider="openai", model="gpt-realtime-2"
    )

    assert audio == b"RIFFrt"
    assert captured["model"] == "gpt-realtime-2"
