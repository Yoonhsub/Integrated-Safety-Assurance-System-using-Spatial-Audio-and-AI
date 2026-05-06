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
        use_mock_data=_env_bool("USE_MOCK_DATA", default=True),
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

    def initialize(self) -> bool:
        """Initialize Firebase Admin SDK if credentials are ready.

        Returns True only when the real Admin SDK is ready. Returns False in
        mock mode or when credentials are incomplete, without raising during
        normal local development/test runs.
        """
        if self._initialized:
            return True
        if self._using_mock or not self.settings.credentials_ready:
            self._using_mock = True
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
            return True
        except Exception as exc:  # pragma: no cover - depends on local credentials
            self.last_error = str(exc)
            self._using_mock = True
            self._initialized = False
            return False

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
