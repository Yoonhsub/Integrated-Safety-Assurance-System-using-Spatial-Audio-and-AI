import logging

import httpx
import pytest

from app.services import v3_gemini_service as service


SECRET = "DO_NOT_LOG_FAKE_SECRET"
PRIVATE = "DO_NOT_LOG_PRIVATE_PROMPT"


def invoke():
    return service._generate_payload(
        model="test-model", system_instruction=PRIVATE, prompt=PRIVATE,
        max_output_tokens=20,
    )


@pytest.fixture(autouse=True)
def isolate(monkeypatch, caplog):
    monkeypatch.setenv("GEMINI_API_KEY", SECRET)
    caplog.set_level(logging.INFO, logger=service._gemini_diagnostic_logger.name)
    monkeypatch.setattr(service.httpx, "post", lambda *a, **k: pytest.fail("Real network forbidden"))
    yield
    for record in caplog.records:
        if record.name == service._gemini_diagnostic_logger.name:
            assert record.exc_info is None
            assert record.stack_info is None
            message = record.getMessage()
            assert SECRET not in message
            assert PRIVATE not in message
            assert "https://" not in message
            assert "response-body" not in message


@pytest.mark.parametrize("status,category", [
    (400, "invalid_request"), (401, "authentication"), (403, "permission"),
    (404, "not_found"), (429, "rate_or_quota"), (500, "upstream_server"),
    (503, "upstream_server"), (418, "http_error"),
])
def test_http_failure_preserves_fallback(monkeypatch, caplog, status, category):
    response = httpx.Response(status, text="response-body" + SECRET + PRIVATE,
        request=httpx.Request("POST", "https://example.invalid/?secret=" + SECRET))
    monkeypatch.setattr(service.httpx, "post", lambda *a, **k: response)
    assert invoke() is None
    assert f"category={category} http_status={status}" in caplog.text


@pytest.mark.parametrize("error,category", [
    (httpx.ReadTimeout(SECRET + PRIVATE), "timeout"),
    (httpx.ConnectError(SECRET + PRIVATE), "transport"),
])
def test_transport_failure(monkeypatch, caplog, error, category):
    def fail(*args, **kwargs):
        raise error
    monkeypatch.setattr(service.httpx, "post", fail)
    assert invoke() is None
    assert f"category={category} http_status=none" in caplog.text


def test_missing_key_no_request(monkeypatch, caplog):
    monkeypatch.delenv("GEMINI_API_KEY")
    assert invoke() is None
    assert "category=missing_configuration" in caplog.text


def test_success_payload_and_request_unchanged(monkeypatch, caplog):
    payload = {"candidates": [{"content": {"parts": [{"text": PRIVATE}]}}]}
    def post(url, **kwargs):
        assert url.endswith("/test-model:generateContent")
        assert kwargs["headers"] == {"x-goog-api-key": SECRET}
        assert kwargs["json"]["contents"][-1]["parts"] == [{"text": PRIVATE}]
        assert kwargs["timeout"] == 5.0
        return httpx.Response(200, json=payload, request=httpx.Request("POST", url))
    monkeypatch.setattr(service.httpx, "post", post)
    assert invoke() == payload
    assert "category=payload_received http_status=200" in caplog.text


def test_invalid_json_still_raises(monkeypatch, caplog):
    response = httpx.Response(200, text="response-body", request=httpx.Request("POST", "https://example.invalid"))
    monkeypatch.setattr(service.httpx, "post", lambda *a, **k: response)
    with pytest.raises(ValueError):
        invoke()
    assert "category=invalid_json http_status=200" in caplog.text


def test_wrong_payload_still_none(monkeypatch, caplog):
    response = httpx.Response(200, json=[], request=httpx.Request("POST", "https://example.invalid"))
    monkeypatch.setattr(service.httpx, "post", lambda *a, **k: response)
    assert invoke() is None
    assert "category=unexpected_payload_type http_status=200" in caplog.text
