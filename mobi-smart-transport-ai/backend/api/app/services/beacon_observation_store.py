"""Bounded per-session radio observations, separate from guidance and cue state.

Lock order is guidance-store -> observation-store. This module never acquires
the guidance lock, writes guidance, or trusts client vehicle identity claims.
"""
from dataclasses import dataclass
from datetime import datetime, timezone
from threading import RLock
import time

from app.schemas.beacon_observation import BeaconObservation, BeaconSessionObservations
from app.schemas.v3 import BeaconIngestRequest, BeaconProximity
from app.services.beacon_registry import beacon_registry, normalize_beacon_id

MAX_OBSERVATIONS_PER_SESSION = 128
MAX_SEEN_KEYS_PER_SESSION = 512


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


@dataclass(frozen=True)
class _Entry:
    request: BeaconIngestRequest
    deadline: float
    unstable: bool


class BeaconObservationStore:
    def __init__(self):
        self._entries: dict[str, dict[tuple[str, str], _Entry]] = {}
        self._seen: dict[str, dict[tuple[str, str], datetime]] = {}
        self._lock = RLock()

    def clear(self, session_id: str) -> None:
        with self._lock:
            self._entries.pop(session_id, None)
            self._seen.pop(session_id, None)

    @staticmethod
    def _remaining(entry: _Entry, now: datetime, mono: float, ttl: float) -> float:
        age = (now - entry.request.timestamp).total_seconds()
        if age < 0:
            return 0
        return max(0, min(entry.deadline - mono, ttl - age))

    def _prune(self, session_id: str, now: datetime, mono: float, ttl: float) -> dict:
        entries = self._entries.get(session_id, {})
        for key, entry in list(entries.items()):
            if self._remaining(entry, now, mono, ttl) <= 0:
                del entries[key]
        if not entries:
            self._entries.pop(session_id, None)
        return entries

    def record(self, request: BeaconIngestRequest, *, ttl: float, unstable_delta: int) -> None:
        now, mono = _utc_now(), time.monotonic()
        stamp = request.timestamp.astimezone(timezone.utc)
        age = (now - stamp).total_seconds()
        if not 0 <= age < ttl:
            return
        request = request.model_copy(update={"timestamp": stamp})
        key = (request.deviceId, normalize_beacon_id(request.beaconId))
        with self._lock:
            seen = self._seen.get(request.sessionId, {})
            if key in seen and stamp <= seen[key]:
                return
            if key not in seen and len(seen) >= MAX_SEEN_KEYS_PER_SESSION:
                return
            entries = self._prune(request.sessionId, now, mono, ttl)
            previous = entries.get(key)
            if previous and stamp <= previous.request.timestamp:
                return
            if key not in entries and len(entries) >= MAX_OBSERVATIONS_PER_SESSION:
                return  # A new unknown radio must not evict a fresh accepted one.
            unstable = bool(previous and abs(request.rssi - previous.request.rssi) >= unstable_delta)
            entries[key] = _Entry(request, mono + ttl - age, unstable)
            self._entries[request.sessionId] = entries
            seen[key] = stamp
            self._seen[request.sessionId] = seen

    def preview(self, session_id: str, *, ttl: float, near: int, mid: int) -> BeaconSessionObservations:
        now, mono = _utc_now(), time.monotonic()
        with self._lock:
            entries = self._prune(session_id, now, mono, ttl)
            items = []
            for entry in entries.values():
                req = entry.request
                distance = req.distanceMeters
                if entry.unstable:
                    proximity = BeaconProximity.UNSTABLE
                elif distance is not None:
                    proximity = BeaconProximity.NEAR if distance <= 3 else (
                        BeaconProximity.MID if distance <= 10 else BeaconProximity.FAR)
                else:
                    proximity = BeaconProximity.NEAR if req.rssi >= near else (
                        BeaconProximity.MID if req.rssi >= mid else BeaconProximity.FAR)
                # Configuration is a label only. Radio advertisements are not authenticated.
                try:
                    assignment = beacon_registry.resolve(req.beaconId, req.macAddress)
                except ValueError:
                    assignment = None
                items.append(BeaconObservation(
                    beaconId=req.beaconId, deviceId=req.deviceId, source=req.source,
                    observedAt=req.timestamp, rssi=req.rssi, distanceMeters=distance,
                    proximity=proximity,
                    validForSeconds=self._remaining(entry, now, mono, ttl),
                    configuredBusId=assignment.bus_id if assignment else None,
                    configuredRouteNo=assignment.route_no if assignment else None,
                    mappingRegistered=assignment is not None,
                ))
            # Display order is signal strength, not an audio/boarding priority decision.
            items.sort(key=lambda item: (-item.rssi, item.beaconId, item.deviceId))
            return BeaconSessionObservations(
                sessionId=session_id, status="AVAILABLE" if items else "EMPTY", observations=items)


beacon_observation_store = BeaconObservationStore()
