"""Authenticated read-only real TAGO checks, independent of application mode."""
from fastapi import APIRouter, Query
from app.schemas.tago_diagnostics import TagoDiagnosticResponse
from app.services.tago_diagnostics_service import TagoDiagnosticsService

router = APIRouter()
_service = TagoDiagnosticsService()

@router.get("/arrivals", response_model=TagoDiagnosticResponse)
def arrivals(cityCode: str = Query(pattern=r"^[0-9]{1,6}$"), stopId: str = Query(pattern=r"^[A-Za-z0-9_-]{1,64}$")):
    return _service.fetch("arrivals", cityCode, stopId)

@router.get("/locations", response_model=TagoDiagnosticResponse)
def locations(cityCode: str = Query(pattern=r"^[0-9]{1,6}$"), routeId: str = Query(pattern=r"^[A-Za-z0-9_-]{1,64}$")):
    return _service.fetch("locations", cityCode, routeId)
