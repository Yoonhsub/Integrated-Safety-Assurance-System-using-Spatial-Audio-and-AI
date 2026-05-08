import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.routes import bus_info_gateway, driver_ride_requests, geofence, notifications, ride_requests
from app.services.firebase_client import get_firebase_client


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


_load_env()
APP_ENV = os.getenv("APP_ENV", "development")
CORS_ORIGINS = _csv_env("BACKEND_CORS_ORIGINS", ("http://localhost:3000", "http://localhost:5173"))

app = FastAPI(
    title="MOBI Backend API",
    version="0.1.0-section10",
    description="FastAPI backend for geofencing, Firebase/FCM, ride matching, and bus info gateway.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=list(CORS_ORIGINS),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_exception_handler(AppServiceError, app_service_error_handler)

app.include_router(geofence.router, prefix="/geofence", tags=["geofence"])
app.include_router(notifications.router, prefix="/notifications", tags=["notifications"])
app.include_router(ride_requests.router, prefix="/ride-requests", tags=["ride-requests"])
app.include_router(bus_info_gateway.router, prefix="/bus-info", tags=["bus-info-gateway"])
app.include_router(driver_ride_requests.router, prefix="/drivers", tags=["driver-ride-requests"])


@app.get("/health")
def health() -> dict[str, str]:
    firebase = get_firebase_client()
    return {
        "status": "ok",
        "service": "mobi-backend-api",
        "environment": APP_ENV,
        "firebaseMode": "mock" if firebase.using_mock else "firebase-admin",
    }
