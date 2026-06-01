"""Dedicated RoutePlan schema boundary.

The V3 endpoint keeps its existing RESOLVED status for compatibility. New
clients can use ``readiness=READY`` when the recommended plan is actionable.
"""

from app.schemas.v3 import (
    RoutePlanCandidate,
    RoutePlanArrivalSummary,
    RoutePlanLeg,
    RoutePlanLegMode,
    RoutePlanReadiness,
    RoutePlanRequest,
    RoutePlanResponse,
    RoutePlanSegment,
    RoutePlanSource,
    RoutePlanStatus,
    RoutePlanStop,
    RoutePlanType,
    RoutePlanVerificationStatus,
)

__all__ = [
    "RoutePlanCandidate",
    "RoutePlanArrivalSummary",
    "RoutePlanLeg",
    "RoutePlanLegMode",
    "RoutePlanReadiness",
    "RoutePlanRequest",
    "RoutePlanResponse",
    "RoutePlanSegment",
    "RoutePlanSource",
    "RoutePlanStatus",
    "RoutePlanStop",
    "RoutePlanType",
    "RoutePlanVerificationStatus",
]
