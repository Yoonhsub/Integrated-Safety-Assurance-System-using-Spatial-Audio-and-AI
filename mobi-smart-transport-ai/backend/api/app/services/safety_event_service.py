from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from app.schemas.safety_event import SafetyEventCreate, SafetyEventRecord, SafetyEventsRecentResponse
from app.services.firebase_client import FirebaseClient, get_firebase_client


class SafetyEventService:
    """Mock/Firebase-backed safety event intake for sensor and AI producers."""

    ROOT_PATH = "/safetyEvents"

    def __init__(self, firebase_client: FirebaseClient | None = None) -> None:
        self.firebase = firebase_client or get_firebase_client()

    def create(self, payload: SafetyEventCreate) -> SafetyEventRecord:
        now = self._utc_now()
        event_id = self._new_event_id()
        timestamp = self._ensure_utc(payload.timestamp or now)
        record = SafetyEventRecord(
            eventId=event_id,
            eventType=payload.eventType,
            source=payload.source,
            userId=payload.userId,
            stopId=payload.stopId,
            routeId=payload.routeId,
            confidence=payload.confidence,
            message=payload.message,
            metadata=dict(payload.metadata),
            timestamp=timestamp,
            createdAt=now,
        )
        payload_without_id = record.model_dump(mode="json", exclude={"eventId"})
        self.firebase.set(self._record_path(event_id), payload_without_id)
        return record

    def recent(self, *, limit: int = 20) -> SafetyEventsRecentResponse:
        raw_events = self.firebase.get(self.ROOT_PATH)
        if not isinstance(raw_events, dict):
            return SafetyEventsRecentResponse(events=[])

        records: list[SafetyEventRecord] = []
        for event_id, value in raw_events.items():
            if not isinstance(value, dict):
                continue
            try:
                records.append(self._record_from_raw(str(event_id), value))
            except ValueError:
                continue

        records.sort(key=lambda item: item.timestamp, reverse=True)
        return SafetyEventsRecentResponse(events=records[:limit])

    @classmethod
    def _record_path(cls, event_id: str) -> str:
        return f"{cls.ROOT_PATH}/{event_id}"

    @staticmethod
    def _utc_now() -> datetime:
        return datetime.now(timezone.utc)

    @staticmethod
    def _ensure_utc(value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("timestamp must include timezone information.")
        return value.astimezone(timezone.utc)

    @staticmethod
    def _new_event_id() -> str:
        return f"safety-{uuid4().hex}"

    @staticmethod
    def _record_from_raw(event_id: str, raw: dict[str, Any]) -> SafetyEventRecord:
        if "eventId" in raw:
            raw = {key: value for key, value in raw.items() if key != "eventId"}
        return SafetyEventRecord.model_validate({"eventId": event_id, **raw})
