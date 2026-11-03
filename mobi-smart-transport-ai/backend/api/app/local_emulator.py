"""Explicit, loopback-only demo environment. Never a production auth bypass."""
import os

from firebase_admin import credentials
from google.auth.credentials import AnonymousCredentials

PROJECT_ID = "demo-mobi-local"
AUTH_HOST = "127.0.0.1:9099"
DATABASE_HOST = "127.0.0.1:9000"
DATABASE_URL = f"https://{PROJECT_ID}-default-rtdb.firebaseio.com"


def emulator_requested() -> bool:
    return bool(os.getenv("FIREBASE_AUTH_EMULATOR_HOST") or os.getenv("FIREBASE_DATABASE_EMULATOR_HOST")
                or os.getenv("MOBI_LOCAL_DEMO") == "1")


def validate_local_emulators() -> None:
    expected = {
        "APP_ENV": "local-demo", "MOBI_LOCAL_DEMO": "1", "FIREBASE_PROJECT_ID": PROJECT_ID,
        "FIREBASE_AUTH_EMULATOR_HOST": AUTH_HOST,
        "FIREBASE_DATABASE_EMULATOR_HOST": DATABASE_HOST,
        "FIREBASE_DATABASE_URL": DATABASE_URL,
        "FIREBASE_USE_MOCK": "false",
    }
    if any(os.getenv(key) != value for key, value in expected.items()):
        raise ValueError("Local demo requires the exact demo project and loopback emulator configuration")
    if any(os.getenv(key) for key in ("K_SERVICE", "GAE_ENV", "FIREBASE_SERVICE_ACCOUNT_PATH", "GOOGLE_APPLICATION_CREDENTIALS")):
        raise ValueError("Local emulators cannot use cloud runtime or production credentials")
    if os.getenv("GOOGLE_CLOUD_PROJECT", PROJECT_ID) != PROJECT_ID:
        raise ValueError("Cloud project differs from local demo project")


class EmulatorCredential(credentials.Base):
    def __init__(self):
        validate_local_emulators()
        super().__init__()

    def get_credential(self):
        validate_local_emulators()
        return AnonymousCredentials()
