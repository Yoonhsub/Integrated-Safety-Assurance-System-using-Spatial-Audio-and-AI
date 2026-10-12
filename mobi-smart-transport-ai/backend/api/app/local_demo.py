"""Run with python -m app.local_demo; binds only to loopback."""
import uvicorn

from app.local_emulator import validate_local_emulators


def create_app():
    validate_local_emulators()
    from app.main import app
    from app.security import firebase_auth_app
    from app.services.firebase_client import get_firebase_client
    firebase_auth_app()
    storage = get_firebase_client()
    if not storage.initialize():
        raise RuntimeError("Local RTDB initialization failed")
    storage.get("/localDemoAssignments")  # actual emulator reachability, no mock fallback
    return app


if __name__ == "__main__":
    uvicorn.run("app.local_demo:create_app", factory=True, host="127.0.0.1", port=8001,
                workers=1, proxy_headers=False)
