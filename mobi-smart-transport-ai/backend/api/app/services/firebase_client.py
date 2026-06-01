from __future__ import annotations

import os
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

from dotenv import load_dotenv


_TRUE_VALUES = {"1", "true", "yes", "y", "on"}


def _project_root() -> Path:
    current = Path(__file__).resolve()
    for parent in current.parents:
        if (parent / ".env.example").exists():
            return parent
    return current.parents[4]


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in _TRUE_VALUES


def _load_env() -> None:
    root = _project_root()
    load_dotenv(root / ".env", override=False)
    load_dotenv(Path.cwd() / ".env", override=False)


@dataclass(frozen=True)
class FirebaseSettings:
    project_id: str | None
    database_url: str | None
    service_account_path: Path | None
    storage_bucket: str | None
    use_mock_data: bool

    @property
    def credentials_ready(self) -> bool:
        return bool(
            self.project_id
            and self.database_url
            and self.service_account_path
            and self.service_account_path.exists()
        )

    @property
    def runtime_mode(self) -> str:
        if self.credentials_ready and not self.use_mock_data:
            return "firebase-admin"
        return "mock"


def load_firebase_settings() -> FirebaseSettings:
    _load_env()
    root = _project_root()
    raw_service_account_path = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH", "").strip()
    service_account_path: Path | None = None
    if raw_service_account_path:
        candidate = Path(raw_service_account_path).expanduser()
        if not candidate.is_absolute():
            candidate = root / candidate
        service_account_path = candidate

    return FirebaseSettings(
        project_id=os.getenv("FIREBASE_PROJECT_ID") or None,
        database_url=os.getenv("FIREBASE_DATABASE_URL") or None,
        service_account_path=service_account_path,
        storage_bucket=os.getenv("FIREBASE_STORAGE_BUCKET") or None,
        use_mock_data=_env_bool("FIREBASE_USE_MOCK", default=_env_bool("USE_MOCK_DATA", default=True)),
    )


class InMemoryRealtimeDatabase:
    """Small RTDB-like fallback used when Firebase credentials are absent."""

    def __init__(self) -> None:
        self._store: dict[str, Any] = {}

    @staticmethod
    def _parts(path: str) -> list[str]:
        return [part for part in path.strip("/").split("/") if part]

    def get(self, path: str) -> Any:
        node: Any = self._store
        for part in self._parts(path):
            if not isinstance(node, dict) or part not in node:
                return None
            node = node[part]
        return deepcopy(node)

    def set(self, path: str, value: Any) -> None:
        parts = self._parts(path)
        if not parts:
            if not isinstance(value, dict):
                raise ValueError("RTDB root value must be a dictionary in mock mode.")
            self._store = deepcopy(value)
            return
        node = self._store
        for part in parts[:-1]:
            node = node.setdefault(part, {})
            if not isinstance(node, dict):
                raise ValueError(f"Cannot create child under non-object path segment: {part}")
        node[parts[-1]] = deepcopy(value)

    def update(self, path: str, value: dict[str, Any]) -> None:
        current = self.get(path)
        if current is None:
            current = {}
        if not isinstance(current, dict):
            raise ValueError("RTDB update target must be an object.")
        current.update(deepcopy(value))
        self.set(path, current)

    def push(self, path: str, value: Any) -> str:
        key = uuid4().hex
        self.set(f"{path.rstrip('/')}/{key}", value)
        return key

    def delete(self, path: str) -> None:
        parts = self._parts(path)
        if not parts:
            self._store.clear()
            return
        node: Any = self._store
        for part in parts[:-1]:
            if not isinstance(node, dict) or part not in node:
                return
            node = node[part]
        if isinstance(node, dict):
            node.pop(parts[-1], None)

    def clear(self) -> None:
        self._store.clear()


class FirebaseClient:
    """Firebase Admin SDK wrapper with a safe mock fallback.

    Importing this module never requires Firebase credentials. The real Admin
    SDK is imported only when `initialize()` is called and the environment is
    fully configured. Without credentials, helpers use an in-memory RTDB-like
    store so local tests remain deterministic.
    """

    # Safe, RTDB-key-compatible probe path. Keys cannot contain "." or "/" so
    # we use a plain top-level node that is created and removed during probing.
    PROBE_PATH = "mobiHealthCheck"

    def __init__(self, settings: FirebaseSettings | None = None) -> None:
        self.settings = settings or load_firebase_settings()
        self._initialized = False
        self._using_mock = self.settings.runtime_mode == "mock"
        self._db_module: Any | None = None
        self._memory_db = InMemoryRealtimeDatabase()
        self.last_error: str | None = None

    @property
    def is_initialized(self) -> bool:
        return self._initialized

    @property
    def using_mock(self) -> bool:
        return self._using_mock

    def initialize(self, force: bool = False) -> bool:
        """Initialize Firebase Admin SDK if credentials are ready.

        Returns True only when the real Admin SDK is ready. Returns False in
        mock mode or when credentials are incomplete, without raising during
        normal local development/test runs.

        When ``force`` is True the current environment is re-read so that a
        service-account file added after process startup can be picked up, and
        a previous initialization attempt is retried.
        """
        if force:
            # Re-read environment so a newly added service account / changed
            # database URL is reflected without restarting the server.
            self.settings = load_firebase_settings()
            self._initialized = False
            self._using_mock = self.settings.runtime_mode == "mock"
            self.last_error = None

        if self._initialized:
            return True
        if self._using_mock or not self.settings.credentials_ready:
            self._using_mock = True
            if not self.settings.credentials_ready and not self.settings.use_mock_data:
                # Configured for real Firebase but credentials are incomplete.
                self.last_error = self._missing_credentials_reason()
            return False

        try:
            import firebase_admin
            from firebase_admin import credentials, db

            if not firebase_admin._apps:
                cred = credentials.Certificate(str(self.settings.service_account_path))
                options = {"databaseURL": self.settings.database_url}
                if self.settings.storage_bucket:
                    options["storageBucket"] = self.settings.storage_bucket
                firebase_admin.initialize_app(cred, options)
            self._db_module = db
            self._initialized = True
            self._using_mock = False
            self.last_error = None
            return True
        except Exception as exc:  # pragma: no cover - depends on local credentials
            self.last_error = str(exc)
            self._using_mock = True
            self._initialized = False
            return False

    def _missing_credentials_reason(self) -> str:
        reasons: list[str] = []
        if not self.settings.project_id:
            reasons.append("FIREBASE_PROJECT_ID 미설정")
        if not self.settings.database_url:
            reasons.append("FIREBASE_DATABASE_URL 미설정")
        if not self.settings.service_account_path:
            reasons.append("FIREBASE_SERVICE_ACCOUNT_PATH 미설정")
        elif not self.settings.service_account_path.exists():
            reasons.append(
                f"서비스 계정 json 파일 없음 ({self.settings.service_account_path})"
            )
        if not reasons:
            return "Firebase 자격 증명이 준비되지 않았습니다."
        return "; ".join(reasons)

    def status(self) -> dict[str, Any]:
        """Return a serializable snapshot of the current Firebase runtime state."""
        service_account_path = (
            str(self.settings.service_account_path)
            if self.settings.service_account_path
            else None
        )
        service_account_exists = bool(
            self.settings.service_account_path
            and self.settings.service_account_path.exists()
        )
        runtime_mode = (
            "firebase-admin" if self._initialized and not self._using_mock else "mock"
        )
        return {
            "projectId": self.settings.project_id,
            "databaseUrl": self.settings.database_url,
            "serviceAccountPath": service_account_path,
            "serviceAccountExists": service_account_exists,
            "credentialsReady": self.settings.credentials_ready,
            "runtimeMode": runtime_mode,
            "initialized": self._initialized,
            "usingMock": self._using_mock,
            "lastError": self.last_error,
        }

    def probe(self) -> dict[str, Any]:
        """Best-effort connectivity check.

        For real Firebase this performs a set/get/delete round-trip against a
        dedicated probe node. For mock mode it round-trips through the in-memory
        store. Never raises; failures are reported in the returned dict.
        """
        from datetime import datetime, timezone

        timestamp = datetime.now(timezone.utc).isoformat()
        payload = {"ts": timestamp, "ok": True}

        if self._using_mock or not self.initialize():
            try:
                self._memory_db.set(self.PROBE_PATH, payload)
                read_back = self._memory_db.get(self.PROBE_PATH)
                self._memory_db.delete(self.PROBE_PATH)
                ok = isinstance(read_back, dict) and read_back.get("ok") is True
                return {
                    "ok": ok,
                    "mode": "mock",
                    "message": "Mock RTDB read/write 정상 동작" if ok else "Mock RTDB 확인 실패",
                }
            except Exception as exc:  # pragma: no cover - defensive
                return {"ok": False, "mode": "mock", "message": f"Mock probe 실패: {exc}"}

        try:
            ref = self._db_module.reference(self.PROBE_PATH)
            ref.set(payload)
            read_back = ref.get()
            ref.delete()
            ok = isinstance(read_back, dict) and read_back.get("ok") is True
            return {
                "ok": ok,
                "mode": "firebase-admin",
                "message": "Firebase Realtime Database 연결 정상"
                if ok
                else "Firebase 연결은 되었으나 응답 확인 필요",
            }
        except Exception as exc:  # pragma: no cover - depends on live Firebase
            self.last_error = str(exc)
            return {
                "ok": False,
                "mode": "firebase-admin",
                "message": (
                    "Firebase Realtime Database 연결 실패. "
                    "Firebase Console의 Realtime Database URL 확인 필요. "
                    f"({exc})"
                ),
            }

    # Backwards/compat alias requested in the spec.
    def test_connection(self) -> dict[str, Any]:
        return self.probe()

    def _real_reference(self, path: str):
        if not self.initialize():
            raise RuntimeError("Firebase Admin SDK is not configured for real RTDB access.")
        return self._db_module.reference(path)

    def get(self, path: str) -> Any:
        if self._using_mock or not self.initialize():
            return self._memory_db.get(path)
        return self._real_reference(path).get()

    def set(self, path: str, value: Any) -> None:
        if self._using_mock or not self.initialize():
            self._memory_db.set(path, value)
            return
        self._real_reference(path).set(value)

    def update(self, path: str, value: dict[str, Any]) -> None:
        if self._using_mock or not self.initialize():
            self._memory_db.update(path, value)
            return
        self._real_reference(path).update(value)

    def push(self, path: str, value: Any) -> str:
        if self._using_mock or not self.initialize():
            return self._memory_db.push(path, value)
        ref = self._real_reference(path).push(value)
        return str(ref.key)

    def delete(self, path: str) -> None:
        if self._using_mock or not self.initialize():
            self._memory_db.delete(path)
            return
        self._real_reference(path).delete()

    def clear_mock_store(self) -> None:
        self._memory_db.clear()


firebase_client = FirebaseClient()


def get_firebase_client() -> FirebaseClient:
    return firebase_client
