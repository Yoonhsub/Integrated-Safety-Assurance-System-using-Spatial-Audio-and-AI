from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable, Any

from app.schemas.v3 import BeaconDecision, GuidanceSessionState, GuidanceState, new_session_id, utc_now


@dataclass
class V3SessionRecord:
    session_id: str
    wake_word: str = "자비스"
    state: GuidanceState = GuidanceState.IDLE
    selected_destination: str | None = None
    selected_route_no: str | None = None
    selected_route_id: str | None = None
    selected_stop_id: str | None = None
    selected_stop_name: str | None = None
    target_bus_id: str | None = None
    selected_plan_id: str | None = None
    origin_location: dict[str, float] | None = None
    nearby_boarding_stops: list[dict[str, Any]] = field(default_factory=list)
    nearby_alighting_stops: list[dict[str, Any]] = field(default_factory=list)
    recommended_plan: dict[str, Any] | None = None
    alternative_plans: list[dict[str, Any]] = field(default_factory=list)
    selected_plan: dict[str, Any] | None = None
    current_leg_index: int = 0
    pending_question: str | None = None
    pending_resolution_status: str | None = None
    pending_heard_text: str | None = None
    pending_top_candidate_name: str | None = None
    pending_choice_names: list[str] = field(default_factory=list)
    pending_origin_lat: float | None = None
    pending_origin_lng: float | None = None
    last_route_plan: dict[str, Any] | None = None
    geofence_armed: bool = False
    last_decision: BeaconDecision | None = None
    nearest_beacon: dict | None = None
    target_bus: dict | None = None
    updated_at: datetime = field(default_factory=utc_now)
    # Optional persistence hook invoked after every state change. Excluded from
    # equality/repr so it never affects API contracts or test comparisons.
    on_touch: Callable[["V3SessionRecord"], None] | None = field(
        default=None, repr=False, compare=False
    )

    def touch(self) -> None:
        self.updated_at = utc_now()
        if self.on_touch is not None:
            try:
                self.on_touch(self)
            except Exception:  # pragma: no cover - persistence is best-effort
                pass

    def to_response(self) -> GuidanceSessionState:
        return GuidanceSessionState(
            sessionId=self.session_id,
            state=self.state,
            wakeWord=self.wake_word,
            selectedDestination=self.selected_destination,
            selectedRouteNo=self.selected_route_no,
            selectedRouteId=self.selected_route_id,
            selectedStopId=self.selected_stop_id,
            selectedStopName=self.selected_stop_name,
            targetBusId=self.target_bus_id,
            selectedPlanId=self.selected_plan_id,
            pendingDestinationCandidates=list(self.pending_choice_names),
            originLocation=self.origin_location,
            nearbyBoardingStops=list(self.nearby_boarding_stops),
            nearbyAlightingStops=list(self.nearby_alighting_stops),
            recommendedPlan=self.recommended_plan,
            alternativePlans=list(self.alternative_plans),
            selectedPlan=self.selected_plan,
            currentLegIndex=self.current_leg_index,
            pendingQuestion=self.pending_question,
            pendingResolutionStatus=self.pending_resolution_status,
            geofenceArmed=self.geofence_armed,
            lastDecision=self.last_decision,
            nearestBeacon=self.nearest_beacon,
            targetBus=self.target_bus,
            updatedAt=self.updated_at,
        )


class V3GuidanceStore:
    """In-memory V3 session store for local demo/test startup safety.

    The in-memory map remains the source of truth for the session lifecycle so
    existing route contracts and tests are unaffected. As a best-effort
    enhancement, every session mutation is mirrored to the Realtime Database at
    ``/v3GuidanceSessions/{sessionId}`` via the shared FirebaseClient — this
    writes to the real RTDB when credentials are present and to the in-memory
    mock store otherwise. Persistence failures are swallowed and never break a
    request.
    """

    def __init__(self) -> None:
        self._sessions: dict[str, V3SessionRecord] = {}

    def _persist(self, record: V3SessionRecord) -> None:
        # Imported lazily to avoid any import-time Firebase side effects.
        from app.services.firebase_client import get_firebase_client

        client = get_firebase_client()
        snapshot = record.to_response().model_dump(mode="json", by_alias=True)
        client.set(f"v3GuidanceSessions/{record.session_id}", snapshot)

    def create(self, *, session_id: str | None = None, wake_word: str = "자비스") -> V3SessionRecord:
        sid = session_id or new_session_id()
        record = V3SessionRecord(session_id=sid, wake_word=wake_word, on_touch=self._persist)
        record.touch()
        self._sessions[sid] = record
        return record

    def get(self, session_id: str = "demo-session", *, wake_word: str = "자비스") -> V3SessionRecord:
        return self._sessions.get(session_id) or self.create(session_id=session_id, wake_word=wake_word)

    def reset(self, session_id: str = "demo-session") -> V3SessionRecord:
        wake_word = self._sessions.get(session_id).wake_word if session_id in self._sessions else "자비스"
        return self.create(session_id=session_id, wake_word=wake_word)

    def clear(self) -> None:
        self._sessions.clear()


v3_guidance_store = V3GuidanceStore()
