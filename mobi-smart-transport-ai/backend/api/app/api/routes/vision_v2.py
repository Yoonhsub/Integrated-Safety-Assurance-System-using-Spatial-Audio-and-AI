"""Versioned, local-only producer intake; legacy admin endpoint is unchanged."""
from uuid import UUID

from fastapi import APIRouter, Response

from app.schemas.vision_v2 import BindingCreate, CameraRegistration, VisionEnvelope, VisionReceipt, VisionCameraState
from app.services.vision_binding_service import vision_binding_service
from app.schemas.vision_v2 import VisionSessionObservations

router = APIRouter()


@router.get("/sessions/{sessionId}/observations", response_model=VisionSessionObservations)
def session_observations(sessionId: str, response: Response):
    response.headers["Cache-Control"] = "no-store"
    return vision_binding_service.preview(sessionId)


@router.put("/cameras/{cameraId}")
def register_camera(cameraId: str, payload: CameraRegistration):
    return vision_binding_service.register(cameraId, payload)


@router.post("/bindings", status_code=201)
def create_binding(payload: BindingCreate):
    return vision_binding_service.bind(payload)


@router.delete("/cameras/{cameraId}/bindings/{bindingId}", status_code=204)
def revoke_binding(cameraId: str, bindingId: UUID):
    vision_binding_service.revoke(cameraId, str(bindingId))
    return Response(status_code=204)


@router.post("/events", status_code=202, response_model=VisionReceipt)
def accept_event(payload: VisionEnvelope):
    return vision_binding_service.accept(payload)


@router.get("/cameras/{cameraId}/state", response_model=VisionCameraState)
def camera_state(cameraId: str):
    return vision_binding_service.state(cameraId)
