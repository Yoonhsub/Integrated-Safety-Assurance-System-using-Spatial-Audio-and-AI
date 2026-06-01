from __future__ import annotations

from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel

from app.services.firebase_client import get_firebase_client
from app.services.firebase_demo_seed_service import FirebaseDemoSeedService

router = APIRouter()


class FirebaseInitializeRequest(BaseModel):
    reset: bool = False


def _status_message(status: dict[str, Any], probe: dict[str, Any]) -> str:
    if not status["credentialsReady"]:
        if not status["serviceAccountExists"]:
            return (
                "서비스 계정 json이 없어 mock 모드로 동작 중입니다. "
                "실제 Firebase에 쓰려면 backend/api/secrets/firebase-service-account.json이 필요합니다."
            )
        return "Firebase 자격 증명이 완전하지 않아 mock 모드로 동작 중입니다."
    if status["usingMock"]:
        return (
            "Firebase 초기화가 아직 수행되지 않았거나 실패해 mock 모드입니다. "
            "/firebase/initialize 를 호출해 초기화하세요."
        )
    return probe.get("message", "Firebase Realtime Database 연결 정상")


@router.get("/status")
def firebase_status() -> dict[str, Any]:
    """Return the current Firebase runtime status with a connectivity probe."""
    client = get_firebase_client()
    # Attempt (re)initialization with current settings so status reflects reality.
    client.initialize()
    status = client.status()
    probe = client.probe()
    # probe() may have flipped runtime state; refresh.
    status = client.status()

    return {
        "ok": True,
        "mode": status["runtimeMode"],
        "initialized": status["initialized"],
        "usingMock": status["usingMock"],
        "credentialsReady": status["credentialsReady"],
        "serviceAccountExists": status["serviceAccountExists"],
        "projectId": status["projectId"],
        "databaseUrl": status["databaseUrl"],
        "serviceAccountPath": status["serviceAccountPath"],
        "lastError": status["lastError"],
        "probe": probe,
        "message": _status_message(status, probe),
    }


@router.post("/initialize")
def firebase_initialize(request: FirebaseInitializeRequest) -> dict[str, Any]:
    """Initialize Firebase (force) and seed demo data into the RTDB.

    Falls back to the in-memory mock store when real credentials are missing.
    Never raises a 500 for missing credentials — it reports mock fallback.
    """
    client = get_firebase_client()
    client.initialize(force=True)

    seed_service = FirebaseDemoSeedService(firebase_client=client)
    result = seed_service.seed(reset=request.reset)

    return {
        "ok": result["ok"],
        "mode": result["mode"],
        "initialized": result["initialized"],
        "usingMock": result["usingMock"],
        "seeded": result["seeded"],
        "reset": result["reset"],
        "seededPaths": result["seededPaths"],
        "errors": result["errors"],
        "lastError": result["lastError"],
        "message": result["message"],
    }
