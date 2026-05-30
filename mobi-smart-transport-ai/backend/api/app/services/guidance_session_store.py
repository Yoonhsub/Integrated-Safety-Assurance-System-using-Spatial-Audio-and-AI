from __future__ import annotations

from app.schemas.guidance import GuidanceSession

_store: dict[str, GuidanceSession] = {}


def get_session(session_id: str) -> GuidanceSession | None:
    return _store.get(session_id)


def save_session(session: GuidanceSession) -> None:
    _store[session.sessionId] = session


def delete_session(session_id: str) -> None:
    _store.pop(session_id, None)


def clear_all() -> None:
    _store.clear()
