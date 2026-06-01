from datetime import datetime, timedelta, timezone

from app.services.ride_request_service import RideRequestService


def test_created_at_is_monotonic_when_clock_resolution_returns_same_value(monkeypatch) -> None:
    service = RideRequestService()
    fixed = datetime(2026, 6, 1, tzinfo=timezone.utc)
    monkeypatch.setattr(service, "_utc_now", lambda: fixed)

    first = service._next_created_at()
    second = service._next_created_at()

    assert first == fixed
    assert second == fixed + timedelta(microseconds=1)
