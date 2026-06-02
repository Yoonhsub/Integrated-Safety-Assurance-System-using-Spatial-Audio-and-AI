from __future__ import annotations

import re
from datetime import datetime
from time import perf_counter
from typing import Any, Callable
from urllib.parse import urlsplit
from uuid import uuid4

from app.schemas.v3 import AgentTraceEvent, utc_now


_REDACTED = "[REDACTED]"
_SECRET_KEY_PATTERN = re.compile(
    r"(?:^key$|api[_-]?key|service[_-]?key|authorization|token|password|secret|"
    r"gemini[_-]?api[_-]?key|kakao[_-]?rest[_-]?api[_-]?key|odsay[_-]?api[_-]?key|"
    r"public[_-]?data[_-]?api[_-]?key)",
    re.IGNORECASE,
)
_COORDINATE_KEY_PATTERN = re.compile(r"(?:lat|lng|latitude|longitude)$", re.IGNORECASE)
_TOKEN_LIKE_PATTERN = re.compile(r"(?<![\w-])[A-Za-z0-9_=-]{32,}(?![\w-])")
_MAX_STRING_LENGTH = 240
_MAX_PAYLOAD_ITEMS = 24
_MAX_LIST_ITEMS = 12
_MAX_DEPTH = 4


class AgentTraceRecorder:
    """Collects short user-facing trace events with defensive redaction.

    A future traceId endpoint can persist these sanitized events without
    exposing raw provider responses or server-only diagnostics.
    """

    def __init__(
        self,
        *,
        trace_id: str | None = None,
        listener: Callable[[str, AgentTraceEvent], None] | None = None,
    ) -> None:
        self.trace_id = trace_id or f"trace-{uuid4().hex}"
        self._events: list[AgentTraceEvent] = []
        self._started: dict[str, tuple[float, datetime]] = {}
        # phase("start"|"end")와 이벤트를 받는 선택적 리스너(실시간 thought 스트리밍용).
        self._listener = listener

    def _emit(self, phase: str, event: AgentTraceEvent) -> None:
        if self._listener is None:
            return
        try:
            self._listener(phase, event)
        except Exception:
            # 리스너 오류가 트레이싱/응답을 깨뜨리지 않게 한다.
            pass

    def start(
        self,
        event_type: str,
        title: str,
        *,
        provider: str | None = None,
        operation: str | None = None,
        safe_payload: dict[str, Any] | None = None,
    ) -> str:
        event_id = f"{self.trace_id}-{len(self._events) + 1}"
        started_at = utc_now()
        self._started[event_id] = (perf_counter(), started_at)
        self._events.append(
            AgentTraceEvent(
                id=event_id,
                step=len(self._events) + 1,
                type=event_type,
                title=title,
                status="RUNNING",
                summary="확인 중이야.",
                provider=provider,
                operation=operation,
                safePayload=self.sanitize_payload(safe_payload or {}),
                startedAt=started_at,
            )
        )
        self._emit("start", self._events[-1])
        return event_id

    def done(
        self,
        event_id: str,
        summary: str,
        *,
        safe_payload: dict[str, Any] | None = None,
        warning: str | None = None,
    ) -> AgentTraceEvent:
        return self._finish(
            event_id,
            status="DONE",
            summary=summary,
            safe_payload=safe_payload,
            warning=warning,
        )

    def fail(
        self,
        event_id: str,
        summary: str,
        *,
        safe_payload: dict[str, Any] | None = None,
        warning: str | None = None,
    ) -> AgentTraceEvent:
        return self._finish(
            event_id,
            status="FAILED",
            summary=summary,
            safe_payload=safe_payload,
            warning=warning or "상세 오류는 숨기고 안전한 대체 경로를 사용했어.",
        )

    def skip(
        self,
        event_type: str,
        title: str,
        summary: str,
        *,
        provider: str | None = None,
        operation: str | None = None,
        safe_payload: dict[str, Any] | None = None,
        warning: str | None = None,
    ) -> AgentTraceEvent:
        now = utc_now()
        event = AgentTraceEvent(
            id=f"{self.trace_id}-{len(self._events) + 1}",
            step=len(self._events) + 1,
            type=event_type,
            title=title,
            status="SKIPPED",
            summary=self._sanitize_text(summary),
            provider=self._sanitize_optional_text(provider),
            operation=self._sanitize_optional_text(operation),
            safePayload=self.sanitize_payload(safe_payload or {}),
            startedAt=now,
            finishedAt=now,
            durationMs=0,
            warning=self._sanitize_optional_text(warning),
        )
        self._events.append(event)
        self._emit("end", event)
        return event

    def record(
        self,
        event_type: str,
        title: str,
        summary: str,
        *,
        status: str = "DONE",
        provider: str | None = None,
        operation: str | None = None,
        safe_payload: dict[str, Any] | None = None,
        warning: str | None = None,
    ) -> AgentTraceEvent:
        if status == "SKIPPED":
            return self.skip(
                event_type,
                title,
                summary,
                provider=provider,
                operation=operation,
                safe_payload=safe_payload,
                warning=warning,
            )
        event_id = self.start(
            event_type,
            title,
            provider=provider,
            operation=operation,
        )
        if status == "FAILED":
            return self.fail(
                event_id,
                summary,
                safe_payload=safe_payload,
                warning=warning,
            )
        return self.done(
            event_id,
            summary,
            safe_payload=safe_payload,
            warning=warning,
        )

    def sanitize_payload(self, payload: Any) -> Any:
        return self._sanitize(payload, depth=0)

    def to_list(self) -> list[AgentTraceEvent]:
        return [event.model_copy(deep=True) for event in self._events]

    def _finish(
        self,
        event_id: str,
        *,
        status: str,
        summary: str,
        safe_payload: dict[str, Any] | None,
        warning: str | None,
    ) -> AgentTraceEvent:
        event = next((item for item in self._events if item.id == event_id), None)
        if event is None:
            raise KeyError("Unknown trace event")
        started_tick, started_at = self._started.pop(event_id, (perf_counter(), utc_now()))
        finished_at = utc_now()
        duration_ms = max(0, int(round((perf_counter() - started_tick) * 1000)))
        updated = event.model_copy(
            update={
                "status": status,
                "summary": self._sanitize_text(summary),
                "safePayload": self.sanitize_payload(safe_payload or event.safePayload),
                "startedAt": started_at,
                "finishedAt": finished_at,
                "durationMs": duration_ms,
                "warning": self._sanitize_optional_text(warning),
            }
        )
        self._events[event.step - 1] = updated
        self._emit("end", updated)
        return updated

    def _sanitize(self, value: Any, *, depth: int) -> Any:
        if depth > _MAX_DEPTH:
            return "[TRUNCATED]"
        if isinstance(value, dict):
            out: dict[str, Any] = {}
            for index, (key, item) in enumerate(value.items()):
                if index >= _MAX_PAYLOAD_ITEMS:
                    out["_truncated"] = True
                    break
                normalized_key = str(key)
                if _SECRET_KEY_PATTERN.search(normalized_key):
                    out[normalized_key] = _REDACTED
                elif _COORDINATE_KEY_PATTERN.search(normalized_key) and isinstance(item, (float, int)):
                    out[normalized_key] = round(float(item), 4)
                else:
                    out[normalized_key] = self._sanitize(item, depth=depth + 1)
            return out
        if isinstance(value, (list, tuple, set)):
            items = list(value)
            sanitized = [self._sanitize(item, depth=depth + 1) for item in items[:_MAX_LIST_ITEMS]]
            if len(items) > _MAX_LIST_ITEMS:
                sanitized.append("[TRUNCATED]")
            return sanitized
        if isinstance(value, float):
            return round(value, 4)
        if isinstance(value, str):
            return self._sanitize_text(value)
        if value is None or isinstance(value, (bool, int)):
            return value
        return self._sanitize_text(str(value))

    def _sanitize_optional_text(self, value: str | None) -> str | None:
        return self._sanitize_text(value) if value else None

    def _sanitize_text(self, value: str) -> str:
        cleaned = value.strip()
        if "://" in cleaned:
            try:
                parsed = urlsplit(cleaned)
            except ValueError:
                return "[URL_REDACTED]"
            if parsed.scheme and parsed.netloc:
                return "[URL_REDACTED]"
        cleaned = _TOKEN_LIKE_PATTERN.sub(_REDACTED, cleaned)
        if len(cleaned) > _MAX_STRING_LENGTH:
            return f"{cleaned[:_MAX_STRING_LENGTH]}..."
        return cleaned
