import os
from pathlib import Path
from typing import Literal

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from app.api.routes import (
    bus_info_gateway,
    driver_ride_requests,
    firebase_admin,
    geofence,
    notifications,
    ride_requests,
    safety_events,
    v3_agent,
    v3_beacon,
    v3_bus,
    v3_guidance,
    v3_map,
    v3_mock,
    v3_navigation,
)
from app.services.firebase_client import get_firebase_client
from pydantic import BaseModel

class DataModeRequest(BaseModel):
    mode: Literal["mock", "live"]



def _project_root() -> Path:
    current = Path(__file__).resolve()
    for parent in current.parents:
        if (parent / ".env.example").exists():
            return parent
    return current.parents[3]


def _load_env() -> None:
    root = _project_root()
    load_dotenv(root / ".env", override=False)
    load_dotenv(Path.cwd() / ".env", override=False)


def _csv_env(name: str, default: tuple[str, ...]) -> tuple[str, ...]:
    value = os.getenv(name)
    if not value:
        return default
    return tuple(item.strip() for item in value.split(",") if item.strip())


class AppServiceError(Exception):
    status_code = 500
    code = "SERVICE_ERROR"

    def __init__(self, message: str, *, detail: dict | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.detail = detail or {}


async def app_service_error_handler(_: Request, exc: AppServiceError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": {"code": exc.code, "message": exc.message, "detail": exc.detail}},
    )


def _http_error_code(status_code: int) -> str:
    return {
        400: "BAD_REQUEST",
        401: "UNAUTHORIZED",
        403: "FORBIDDEN",
        404: "NOT_FOUND",
        409: "CONFLICT",
        422: "INVALID_REQUEST",
        503: "SERVICE_UNAVAILABLE",
    }.get(status_code, "HTTP_ERROR")


async def http_exception_handler(_: Request, exc: HTTPException) -> JSONResponse:
    if isinstance(exc.detail, dict) and isinstance(exc.detail.get("error"), dict):
        return JSONResponse(status_code=exc.status_code, content=exc.detail)
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "code": _http_error_code(exc.status_code),
                "message": str(exc.detail),
                "detail": {"detail": exc.detail},
            }
        },
    )


_load_env()
APP_ENV = os.getenv("APP_ENV", "development")
CORS_ORIGINS = _csv_env("BACKEND_CORS_ORIGINS", ("http://localhost:3000", "http://localhost:5173"))
PASSENGER_WEB_BUILD_DIR = _project_root() / "apps" / "passenger_app" / "build" / "web"

app = FastAPI(
    title="MOBI Backend API",
    version="0.1.0-v3-section1",
    description="FastAPI backend for geofencing, Firebase/FCM, ride matching, bus info gateway, and V3 bus guidance demo routes.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=list(CORS_ORIGINS),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_exception_handler(AppServiceError, app_service_error_handler)
app.add_exception_handler(HTTPException, http_exception_handler)

app.include_router(geofence.router, prefix="/geofence", tags=["geofence"])
app.include_router(notifications.router, prefix="/notifications", tags=["notifications"])
app.include_router(ride_requests.router, prefix="/ride-requests", tags=["ride-requests"])
app.include_router(bus_info_gateway.router, prefix="/bus-info", tags=["bus-info-gateway"])
app.include_router(driver_ride_requests.router, prefix="/drivers", tags=["driver-ride-requests"])
app.include_router(driver_ride_requests.alias_router, prefix="/driver", tags=["driver-ride-requests"])
app.include_router(safety_events.router, prefix="/safety-events", tags=["safety-events"])
app.include_router(firebase_admin.router, prefix="/firebase", tags=["firebase-admin"])

# V3 voice-first bus boarding assistant routes.
# Safety-critical guidance remains backend-rule based; Gemini is optional fallback only.
app.include_router(v3_guidance.router, prefix="/guidance", tags=["v3-guidance"])
app.include_router(v3_agent.router, prefix="/agent", tags=["v3-agent"])
app.include_router(v3_bus.router, prefix="/bus", tags=["v3-bus"])
app.include_router(v3_beacon.router, prefix="/beacon", tags=["v3-beacon"])
app.include_router(v3_mock.router, prefix="/mock", tags=["v3-mock"])
# 실시간 지도/내비게이션 지원 라우트(보행경로·근처정류장·통합 실시간 상태).
app.include_router(v3_map.router, prefix="/map", tags=["v3-map"])
app.include_router(v3_navigation.router, prefix="/navigation", tags=["v3-navigation"])


@app.get("/health")
def health() -> dict[str, object]:
    firebase = get_firebase_client()
    return {
        "status": "ok",
        "service": "mobi-backend-api",
        "environment": APP_ENV,
        "firebaseMode": "mock" if firebase.using_mock else "firebase-admin",
        "firebaseInitialized": firebase.is_initialized,
        "firebaseCredentialsReady": firebase.settings.credentials_ready,
        "firebaseLastError": firebase.last_error,
        "dataMode": "mock" if os.getenv("PUBLIC_DATA_USE_MOCK", "true").lower() in ("true", "1", "yes") else "live",
    }


@app.get("/", include_in_schema=False)
def passenger_app_root() -> RedirectResponse:
    if not (PASSENGER_WEB_BUILD_DIR / "index.html").is_file():
        raise HTTPException(status_code=404, detail="Passenger web app has not been deployed.")
    return RedirectResponse(url="/app/")


@app.post("/config/data-mode", tags=["config"])
def set_data_mode(request: DataModeRequest) -> dict[str, str]:
    # Data mode is a client-scoped choice. V3 requests already send mode, so
    # mutating process-wide state here can leak one user's selection to others.
    return {"status": "success", "mode": request.mode}


if PASSENGER_WEB_BUILD_DIR.is_dir():
    app.mount("/app", StaticFiles(directory=PASSENGER_WEB_BUILD_DIR, html=True), name="passenger-app")
