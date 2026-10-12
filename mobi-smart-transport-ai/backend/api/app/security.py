"""Firebase authentication and explicit endpoint policy. No runtime mock bypass."""
from __future__ import annotations

import asyncio
import os
import time
from contextvars import ContextVar
from dataclasses import dataclass
from pathlib import Path
from threading import Lock

import firebase_admin
from firebase_admin import auth, credentials
from fastapi import Depends, HTTPException, WebSocketException
from starlette.concurrency import run_in_threadpool
from starlette.requests import HTTPConnection


@dataclass(frozen=True)
class Principal:
    uid: str
    role: str
    driver_id: str | None = None
    expires_at: float | None = None


current_principal: ContextVar[Principal | None] = ContextVar("principal", default=None)
_auth_lock = Lock()
PUBLIC = {
    ("GET", "/health"), ("GET", "/"),
    ("GET", "/bus-info/stops/{stopId}/arrivals"), ("GET", "/bus/arrivals"),
}
# Deliberate per-operation allowlist: newly added endpoints default to denied.
POLICY = {
    ("POST", "/ride-requests"): {"passenger", "admin"},
    ("GET", "/ride-requests/{requestId}"): {"passenger", "driver", "admin"},
    ("PATCH", "/ride-requests/{requestId}/status"): {"passenger", "driver", "admin"},
    ("GET", "/drivers/{driverId}/ride-requests"): {"driver", "admin"},
    ("GET", "/driver/ride-requests"): {"driver", "admin"},
    ("PATCH", "/driver/ride-requests/{requestId}/status"): {"driver", "admin"},
    ("POST", "/geofence/check"): {"passenger", "admin"},
    ("POST", "/guidance/session"): {"passenger", "admin"},
    ("GET", "/guidance/state"): {"passenger", "admin"},
    ("POST", "/guidance/reset"): {"passenger", "admin"},
    ("GET", "/beacon/decision"): {"passenger", "admin"},
    ("POST", "/agent/converse"): {"passenger", "admin"},
    ("POST", "/agent/tts"): {"passenger", "admin"},
    ("WS", "/agent/converse/live"): {"passenger", "admin"},
    ("WS", "/agent/tts/live"): {"passenger", "admin"},
    ("WS", "/agent/stt/live"): {"passenger", "admin"},
}
for method, path in [
    ("POST", "/notifications/send"), ("POST", "/safety-events"),
    ("GET", "/safety-events/recent"), ("POST", "/ai-vision/events"),
    ("GET", "/firebase/status"), ("POST", "/firebase/initialize"),
    ("POST", "/guidance/event"), ("POST", "/api/v3/beacon/ingest"),
    ("GET", "/api/v3/beacon/latest"), ("POST", "/api/v3/beacon/reset"),
    ("POST", "/mock/geofence"), ("POST", "/mock/beacons"), ("POST", "/mock/bus-event"),
]:
    POLICY[method, path] = {"admin"}
for method, path in [
    ("GET", "/bus/destination-candidates"), ("GET", "/bus/route-plan"),
    ("POST", "/bus/route-plan"), ("GET", "/bus/route-recommend"),
    ("GET", "/bus/live-route-status"), ("GET", "/map/nearby-stops"),
    ("GET", "/map/walking-route"), ("GET", "/navigation/live-status"),
    ("POST", "/config/data-mode"),
]:
    POLICY[method, path] = {"passenger", "driver", "admin"}


def auth_error(status: int, message: str) -> HTTPException:
    return HTTPException(status, message, headers={"WWW-Authenticate": "Bearer"} if status == 401 else None)


def require_role(*roles: str) -> Principal:
    principal = current_principal.get()
    if principal is None:
        raise auth_error(401, "Authentication required")
    if principal.role not in roles and principal.role != "admin":
        raise auth_error(403, "Permission denied")
    return principal


def valid_key(value: object) -> bool:
    return (isinstance(value, str) and 0 < len(value) <= 128
            and not any(c in value for c in ".#$[]/\\")
            and all(ord(c) >= 32 and ord(c) != 127 for c in value))


def firebase_auth_app():
    # A named app avoids trusting the storage client's mock/fallback state.
    # Unsigned emulator tokens are accepted only in the isolated local demo.
    from app.local_emulator import emulator_requested, validate_local_emulators, EmulatorCredential
    local_demo = emulator_requested()
    if local_demo:
        try:
            validate_local_emulators()
        except ValueError:
            raise auth_error(503, "Authentication service unavailable") from None
    project_id = os.getenv("FIREBASE_PROJECT_ID", "").strip()
    if not project_id:
        raise auth_error(503, "Authentication service is not configured")
    with _auth_lock:
        try:
            app = firebase_admin.get_app("mobi-auth")
            if app.project_id != project_id:
                raise auth_error(503, "Authentication configuration changed; restart required")
            return app
        except ValueError:
            pass
        try:
            credential_path = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH", "").strip()
            if local_demo:
                credential = EmulatorCredential()
            elif credential_path:
                path = Path(credential_path)
                if not path.is_absolute():
                    path = Path(__file__).resolve().parents[3] / path
                credential = credentials.Certificate(str(path))
            else:
                credential = credentials.ApplicationDefault()
            return firebase_admin.initialize_app(
                credential, {"projectId": project_id, "httpTimeout": 5}, name="mobi-auth"
            )
        except Exception:
            raise auth_error(503, "Authentication service unavailable") from None


def verify_user(token: str) -> Principal:
    app = firebase_auth_app()
    try:
        claims = auth.verify_id_token(token, app=app, check_revoked=True, clock_skew_seconds=0)
        uid = claims["uid"]
        # Current server-managed claims, not potentially stale role claims in token.
        user = auth.get_user(uid, app=app)
        if user.disabled:
            raise auth_error(401, "Invalid or expired authentication")
    except HTTPException:
        raise
    except (auth.InvalidIdTokenError, auth.UserDisabledError, auth.UserNotFoundError, ValueError):
        raise auth_error(401, "Invalid or expired authentication") from None
    except Exception:
        # Includes certificate fetch, IAM, account lookup/network and service errors.
        raise auth_error(503, "Authentication service unavailable") from None
    role_claims = user.custom_claims or {}
    role = role_claims.get("mobi_role")
    driver_id = role_claims.get("mobi_driver_id")
    if not valid_key(uid) or not isinstance(role, str) or role not in {"passenger", "driver", "admin"}:
        raise auth_error(403, "Account role is not provisioned")
    if role == "driver" and not valid_key(driver_id):
        raise auth_error(403, "Driver mapping is not provisioned")
    return Principal(uid, role, driver_id if role == "driver" else None, float(claims["exp"]))


def operation(connection: HTTPConnection) -> tuple[str, str]:
    method = "WS" if connection.scope["type"] == "websocket" else connection.scope["method"]
    return method, connection.scope["route"].path


async def get_principal(connection: HTTPConnection) -> Principal | None:
    if operation(connection) in PUBLIC:
        return None
    value = connection.headers.get("authorization", "")
    parts = value.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        error = auth_error(401, "Authentication required")
    else:
        try:
            return await run_in_threadpool(verify_user, parts[1])
        except HTTPException as exc:
            error = exc
    if connection.scope["type"] == "websocket":
        raise WebSocketException(code=1011 if error.status_code == 503 else 1008, reason="Authentication required or unavailable")
    raise error


async def authorize_api(connection: HTTPConnection, principal=Depends(get_principal)):
    key = operation(connection)
    if key in PUBLIC:
        yield
        return
    allowed = POLICY.get(key, set())
    if principal is None or principal.role not in allowed:
        if connection.scope["type"] == "websocket":
            raise WebSocketException(code=1008, reason="Permission denied")
        raise auth_error(401 if principal is None else 403, "Permission denied")
    if key[1].startswith("/mock/") and os.getenv("APP_ENV", "development").lower() not in {"development", "test", "local"}:
        raise auth_error(403, "Demo mutations are disabled")
    marker = current_principal.set(principal)
    timer = None
    if connection.scope["type"] == "websocket" and principal.expires_at is not None:
        async def expire():
            # Bound long connections; reconnect rechecks revocation/current role.
            await asyncio.sleep(max(0, min(60, principal.expires_at - time.time())))
            try:
                await connection.close(code=1008, reason="Reauthentication required")
            except RuntimeError:
                pass
        timer = asyncio.create_task(expire())
    try:
        yield
    finally:
        if timer:
            timer.cancel()
        current_principal.reset(marker)
