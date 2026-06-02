from __future__ import annotations

import json
import os
from datetime import datetime, time
from typing import Iterable
from zoneinfo import ZoneInfo

from app.schemas.v3 import RoutePlanServiceStatus


_DEFAULT_FIRST = "05:30"
_DEFAULT_LAST = "23:30"


def evaluate_route_service_status(
    *,
    route_no: str | None,
    arrivals: Iterable[object],
    now: datetime | time | None = None,
) -> RoutePlanServiceStatus:
    arrival_list = list(arrivals)
    first, last, source = _service_window(route_no)
    if arrival_list:
        return RoutePlanServiceStatus(
            operatingNow=True,
            reason="ARRIVALS_AVAILABLE",
            message="현재 도착 예정 버스가 확인됐어.",
            scheduleSource=source,
        )

    current = _current_time(now)
    if _within_window(current, first, last):
        return RoutePlanServiceStatus(
            operatingNow=True,
            reason="ARRIVAL_INFO_UNAVAILABLE_WITHIN_SERVICE_WINDOW",
            message="현재 도착정보가 확인되지 않아. 잠시 후 다시 갱신해줘.",
            scheduleSource=source,
        )

    next_time = first.strftime("%H:%M")
    next_label = first.strftime("%H시%M분")
    return RoutePlanServiceStatus(
        operatingNow=False,
        reason="OUTSIDE_SERVICE_WINDOW",
        message=f"지금 운행 중인 버스가 없어. 가장 빠른 버스는 {next_label}에 운행할 예정이야.",
        nextServiceTime=next_time,
        nextServiceLabel=next_label,
        scheduleSource=source,
    )


def _service_window(route_no: str | None) -> tuple[time, time, str]:
    route_windows = _route_windows()
    if route_no and route_no in route_windows:
        window = route_windows[route_no]
        return window[0], window[1], "ENV_ROUTE_OVERRIDE"

    default = os.getenv("CHEONGJU_DEFAULT_ROUTE_SERVICE_WINDOW", "").strip()
    if default and "~" in default:
        first_raw, last_raw = default.split("~", 1)
        first = _parse_time(first_raw)
        last = _parse_time(last_raw)
        if first is not None and last is not None:
            return first, last, "ENV_DEFAULT_OVERRIDE"
    return _parse_time(_DEFAULT_FIRST), _parse_time(_DEFAULT_LAST), "DEFAULT_FALLBACK"


def _route_windows() -> dict[str, tuple[time, time]]:
    raw = os.getenv("CHEONGJU_ROUTE_SERVICE_WINDOWS", "").strip()
    if not raw:
        return {}
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(decoded, dict):
        return {}

    windows: dict[str, tuple[time, time]] = {}
    for route_no, value in decoded.items():
        if not isinstance(route_no, str) or not isinstance(value, dict):
            continue
        first = _parse_time(value.get("first"))
        last = _parse_time(value.get("last"))
        if first is not None and last is not None:
            windows[route_no.strip()] = (first, last)
    return windows


def _parse_time(value: object) -> time | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value.strip(), "%H:%M").time()
    except ValueError:
        return None


def _current_time(value: datetime | time | None) -> time:
    if isinstance(value, datetime):
        return value.time().replace(tzinfo=None)
    if isinstance(value, time):
        return value.replace(tzinfo=None)
    timezone_name = os.getenv("CHEONGJU_TIMEZONE", "Asia/Seoul").strip() or "Asia/Seoul"
    try:
        zone = ZoneInfo(timezone_name)
    except Exception:
        zone = ZoneInfo("Asia/Seoul")
    return datetime.now(zone).time().replace(tzinfo=None)


def _within_window(current: time, first: time, last: time) -> bool:
    if first <= last:
        return first <= current <= last
    return current >= first or current <= last
