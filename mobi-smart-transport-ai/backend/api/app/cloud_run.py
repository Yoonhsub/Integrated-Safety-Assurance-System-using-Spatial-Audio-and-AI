"""Cloud Run entry point; deployment configuration must fail closed."""
import os
from urllib.parse import urlparse

import uvicorn


def validate_environment() -> None:
    if os.getenv("APP_ENV") not in {"production", "staging"}:
        raise RuntimeError("Cloud Run requires APP_ENV=production or staging")
    for name in ("FIREBASE_PROJECT_ID", "FIREBASE_DATABASE_URL", "BACKEND_CORS_ORIGINS"):
        if not os.getenv(name, "").strip() or "<" in os.environ[name]:
            raise RuntimeError(f"Missing deployment configuration: {name}")
    for name in ("FIREBASE_AUTH_EMULATOR_HOST", "FIREBASE_DATABASE_EMULATOR_HOST"):
        if os.getenv(name):
            raise RuntimeError("Emulator settings are not allowed in Cloud Run")
    for origin in os.environ["BACKEND_CORS_ORIGINS"].split(","):
        parsed = urlparse(origin.strip())
        if (parsed.scheme != "https" or not parsed.hostname or "*" in origin
                or parsed.username or parsed.password or parsed.query or parsed.fragment
                or parsed.path not in {"", "/"}):
            raise RuntimeError("Cloud Run CORS requires explicit HTTPS origins")
    from app.services.firebase_client import load_firebase_settings
    settings = load_firebase_settings()
    if settings.use_mock_data or not settings.credentials_ready:
        raise RuntimeError("Cloud Run requires real Firebase storage credentials")
    database = urlparse(settings.database_url)
    if database.scheme != "https" or not database.hostname or database.username or database.password:
        raise RuntimeError("Firebase database URL must use HTTPS")


def create_app():
    validate_environment()
    from app.main import app
    from app.security import firebase_auth_app
    from app.services.firebase_client import get_firebase_client

    def initialize_firebase() -> None:
        firebase_auth_app()
        if not get_firebase_client().initialize():
            raise RuntimeError("Firebase storage initialization failed")

    app.add_event_handler("startup", initialize_firebase)
    return app


if __name__ == "__main__":
    uvicorn.run("app.cloud_run:create_app", factory=True, host="0.0.0.0",
                port=int(os.getenv("PORT", "8080")), workers=1)
