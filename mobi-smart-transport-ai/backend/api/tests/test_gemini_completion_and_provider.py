import pytest

from app.services import v3_gemini_service as gemini


def _payload(reason: str, text: str = "완전한 안내입니다.") -> dict:
    return {
        "candidates": [{
            "finishReason": reason,
            "content": {"parts": [{"text": text}]},
        }]
    }


def test_gemini_only_accepts_stop_and_rejects_truncated_or_refused_text() -> None:
    assert gemini._extract_text(_payload("STOP")) == "완전한 안내입니다."
    assert gemini._extract_text(_payload("MAX_TOKENS", "미완성 안내")) is None
    assert gemini._extract_text(_payload("SAFETY", "거절된 안내")) is None
    assert gemini._extract_text({"candidates": [{"content": {"parts": [{"text": "unknown"}]}}]}) is None


@pytest.mark.parametrize("budget", [None, 0, 128])
def test_gemini_35_payload_uses_level_and_preserves_25_budget(monkeypatch, budget) -> None:
    class Response:
        status_code = 200

        def raise_for_status(self):
            pass

        def json(self):
            return {"candidates": []}

    calls = []

    def post(url, **kwargs):
        calls.append(kwargs)
        return Response()

    monkeypatch.setenv("GEMINI_API_KEY", "unit-test-only")
    monkeypatch.setattr(gemini.httpx, "post", post)
    assert gemini._generate_payload(
        model="gemini-3.5-flash-lite",
        system_instruction="test",
        prompt="test",
        max_output_tokens=64,
        thinking_budget=budget,
    ) == {"candidates": []}
    assert calls[0]["json"]["generationConfig"]["thinkingConfig"] == {
        "thinkingLevel": "MINIMAL"
    }

    calls.clear()
    assert gemini._generate_payload(
        model="gemini-2.5-flash",
        system_instruction="test",
        prompt="test",
        max_output_tokens=64,
        thinking_budget=budget,
    ) == {"candidates": []}
    config = calls[0]["json"]["generationConfig"]
    if budget is None:
        assert "thinkingConfig" not in config
    else:
        assert config["thinkingConfig"] == {"thinkingBudget": budget}


def test_overlength_gemini_and_openai_text_is_rejected_without_clipping(monkeypatch) -> None:
    too_long = "가" * (gemini._MAX_REPLY_LENGTH + 1)
    assert gemini._extract_text(_payload("STOP", too_long)) is None

    class Response:
        def raise_for_status(self):
            return None

        def json(self):
            return {"choices": [{"finish_reason": "stop", "message": {"content": too_long}}]}

    monkeypatch.setenv("OPENAI_API_KEY", "unit-test-key")
    monkeypatch.setattr(gemini.httpx, "post", lambda *args, **kwargs: Response())
    assert gemini._openai_generate(system_instruction="", prompt="", max_output_tokens=900) is None


def test_openai_length_finish_reason_is_rejected(monkeypatch) -> None:
    class Response:
        def raise_for_status(self):
            return None

        def json(self):
            return {"choices": [{"finish_reason": "length", "message": {"content": "미완성 안내"}}]}

    monkeypatch.setenv("OPENAI_API_KEY", "unit-test-key")
    monkeypatch.setattr(gemini.httpx, "post", lambda *args, **kwargs: Response())
    assert gemini._openai_generate(system_instruction="", prompt="", max_output_tokens=32) is None


def test_auto_fallback_reports_actual_openai_provider_and_model(monkeypatch) -> None:
    monkeypatch.setenv("OPENAI_NLU_MODEL", "gpt-test-model")
    gemini.set_nlu_provider("auto")
    monkeypatch.setattr(gemini, "_generate_payload", lambda **_: _payload("MAX_TOKENS", "partial"))
    monkeypatch.setattr(gemini, "_openai_generate", lambda **_: "완결된 대체 안내입니다.")

    result = gemini._generate(
        model="gemini-test-pro",
        system_instruction="",
        prompt="",
        max_output_tokens=128,
    )

    assert result == "완결된 대체 안내입니다."
    assert gemini.get_last_nlu_provider() == "openai"
    assert gemini.get_last_nlu_model() == "gpt-test-model"


def test_safety_refusal_does_not_fall_back_to_another_provider(monkeypatch) -> None:
    gemini.set_nlu_provider("auto")
    monkeypatch.setattr(gemini, "_generate_payload", lambda **_: _payload("SAFETY", "blocked"))
    calls = []
    monkeypatch.setattr(gemini, "_openai_generate", lambda **_: calls.append("openai"))

    result = gemini._generate(
        model="gemini-test-pro",
        system_instruction="",
        prompt="",
        max_output_tokens=128,
    )

    assert result is None
    assert calls == []
    assert gemini.get_last_nlu_provider() is None
    assert gemini.get_last_nlu_model() is None


def test_unknown_finish_reason_is_not_logged(caplog):
    assert gemini._extract_text(_payload("sensitive-provider-value")) is None
    assert "sensitive-provider-value" not in caplog.text
    assert gemini._extract_text({"candidates": [None]}) is None
