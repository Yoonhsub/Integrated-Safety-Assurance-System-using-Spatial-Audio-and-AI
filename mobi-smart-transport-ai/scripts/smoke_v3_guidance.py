from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any
from uuid import uuid4

DEFAULT_BASE_URL = "http://127.0.0.1:8000"


@dataclass(frozen=True)
class StepResult:
    label: str
    status: int
    body: dict[str, Any]


class SmokeFailure(AssertionError):
    pass


class V3HttpClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")

    def get(self, path: str, *, params: dict[str, Any] | None = None, label: str) -> StepResult:
        query = f"?{urllib.parse.urlencode(params)}" if params else ""
        return self._request("GET", f"{path}{query}", None, label)

    def post(self, path: str, *, payload: dict[str, Any], label: str) -> StepResult:
        return self._request("POST", path, payload, label)

    def _request(self, method: str, path: str, payload: dict[str, Any] | None, label: str) -> StepResult:
        url = f"{self.base_url}{path}"
        data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                raw = response.read().decode("utf-8")
                body = json.loads(raw) if raw else {}
                return StepResult(label=label, status=response.status, body=body)
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            try:
                body = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                body = {"raw": raw}
            raise SmokeFailure(f"{label}: HTTP {exc.code} from {url}: {body}") from exc
        except urllib.error.URLError as exc:
            raise SmokeFailure(
                f"{label}: cannot connect to {url}. Start FastAPI first, for example: "
                "cd backend/api && python -m uvicorn app.main:app --host 127.0.0.1 --port 8000"
            ) from exc
        except TimeoutError as exc:
            raise SmokeFailure(f"{label}: timed out calling {url}") from exc


def require(condition: bool, label: str, detail: Any) -> None:
    if not condition:
        raise SmokeFailure(f"{label}: assertion failed: {detail}")


def print_step(result: StepResult) -> None:
    print(f"[PASS] {result.label} -> HTTP {result.status}")


def main() -> int:
    base_url = os.getenv("V3_API_BASE_URL", DEFAULT_BASE_URL)
    session_id = os.getenv("V3_SMOKE_SESSION_ID", f"v3-smoke-{uuid4().hex[:12]}")
    wake_word = os.getenv("V3_WAKE_WORD", "자비스")
    client = V3HttpClient(base_url)

    print(f"V3 guidance smoke base URL: {base_url}")
    print(f"V3 guidance smoke sessionId: {session_id}")

    health = client.get("/health", label="1. GET /health")
    require(health.body.get("status") == "ok", health.label, health.body)
    print_step(health)

    session = client.post(
        "/guidance/session",
        payload={"sessionId": session_id, "wakeWord": wake_word},
        label="2. POST /guidance/session",
    )
    require(session.body.get("state") == "IDLE", session.label, session.body)
    print_step(session)

    find_route = client.post(
        "/agent/converse",
        payload={
            "sessionId": session_id,
            "wakeWord": wake_word,
            "utterance": "자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?",
        },
        label="3. POST /agent/converse FIND_ROUTE",
    )
    require(find_route.body.get("intent") == "FIND_ROUTE", find_route.label, find_route.body)
    require(find_route.body.get("state") == "ROUTE_RECOMMENDED", find_route.label, find_route.body)
    print_step(find_route)

    arrivals = client.get(
        "/bus/arrivals",
        params={"stopId": "mock-stop-001", "routeNo": "502"},
        label="4. GET /bus/arrivals mock-stop-001 route 502",
    )
    body_arrivals = arrivals.body.get("arrivals") or []
    require(arrivals.body.get("fallbackSource") in {"MOCK", "CACHE", "PUBLIC_API"}, arrivals.label, arrivals.body)
    require(len(body_arrivals) >= 1, arrivals.label, arrivals.body)
    require(body_arrivals[0].get("routeNo") == "502", arrivals.label, arrivals.body)
    require(body_arrivals[0].get("busId") == "BUS_2", arrivals.label, arrivals.body)
    require(body_arrivals[0].get("congestion") is None, arrivals.label, "mock congestion must not be invented")
    print_step(arrivals)

    query_arrival = client.post(
        "/agent/converse",
        payload={"sessionId": session_id, "wakeWord": wake_word, "utterance": "자비스, 그 버스 언제 와?"},
        label="5. POST /agent/converse QUERY_ARRIVAL",
    )
    require(query_arrival.body.get("intent") == "QUERY_ARRIVAL", query_arrival.label, query_arrival.body)
    print_step(query_arrival)

    select_arrival = client.post(
        "/agent/converse",
        payload={"sessionId": session_id, "wakeWord": wake_word, "utterance": "응, 6분 뒤 오는 걸로 안내해줘."},
        label="6. POST /agent/converse SELECT_ARRIVAL",
    )
    require(select_arrival.body.get("intent") == "SELECT_ARRIVAL", select_arrival.label, select_arrival.body)
    require(select_arrival.body.get("state") == "WAITING_FOR_BUS", select_arrival.label, select_arrival.body)
    print_step(select_arrival)

    arrived = client.post(
        "/mock/geofence",
        payload={"sessionId": session_id, "event": "ARRIVED_AT_STOP"},
        label="7. POST /mock/geofence ARRIVED_AT_STOP",
    )
    require(arrived.body.get("geofenceArmed") is True, arrived.label, arrived.body)
    print_step(arrived)

    left_area = client.post(
        "/mock/geofence",
        payload={"sessionId": session_id, "event": "LEFT_WAITING_AREA"},
        label="8. POST /mock/geofence LEFT_WAITING_AREA",
    )
    require(left_area.body.get("cue", {}).get("type") == "GEOFENCE_WARNING", left_area.label, left_area.body)
    require(left_area.body.get("cue", {}).get("ttsMode") == "SAFETY_LOCAL", left_area.label, left_area.body)
    print_step(left_area)

    wrong_bus = client.post(
        "/mock/beacons",
        payload={
            "sessionId": session_id,
            "targetBusId": "BUS_2",
            "targetRouteNo": "502",
            "beacons": [
                {"busId": "BUS_1", "routeNo": "511", "rssi": -50, "distanceMeters": 1.5},
                {"busId": "BUS_2", "routeNo": "502", "rssi": -70, "distanceMeters": 7.0},
            ],
        },
        label="9. POST /mock/beacons wrong bus near + target mid",
    )
    require(wrong_bus.body.get("decision") == "WRONG_BUS_NEAR", wrong_bus.label, wrong_bus.body)
    print_step(wrong_bus)

    can_board_no = client.post(
        "/agent/converse",
        payload={"sessionId": session_id, "wakeWord": wake_word, "utterance": "자비스, 지금 앞에 온 버스 타도 돼?"},
        label="10. POST /agent/converse ASK_CAN_BOARD negative",
    )
    require(can_board_no.body.get("intent") == "ASK_CAN_BOARD_CURRENT_BUS", can_board_no.label, can_board_no.body)
    require(can_board_no.body.get("cue", {}).get("type") == "WRONG_BUS_NEAR", can_board_no.label, can_board_no.body)
    print_step(can_board_no)

    target_near = client.post(
        "/mock/beacons",
        payload={
            "sessionId": session_id,
            "targetBusId": "BUS_2",
            "targetRouteNo": "502",
            "beacons": [{"busId": "BUS_2", "routeNo": "502", "rssi": -50, "distanceMeters": 1.5}],
        },
        label="11. POST /mock/beacons target bus near",
    )
    require(target_near.body.get("decision") == "TARGET_BUS_NEAR", target_near.label, target_near.body)
    print_step(target_near)

    bus_passed = client.post(
        "/mock/bus-event",
        payload={"sessionId": session_id, "event": "BUS_PASSED"},
        label="12. POST /mock/bus-event BUS_PASSED",
    )
    require(bus_passed.body.get("state") == "MISSED_BUS", bus_passed.label, bus_passed.body)
    print_step(bus_passed)

    missed = client.post(
        "/agent/converse",
        payload={"sessionId": session_id, "wakeWord": wake_word, "utterance": "자비스, 나 못 탔어."},
        label="13. POST /agent/converse REPORT_MISSED_BUS",
    )
    require(missed.body.get("intent") == "REPORT_MISSED_BUS", missed.label, missed.body)
    require(missed.body.get("state") == "WAITING_FOR_BUS", missed.label, missed.body)
    print_step(missed)

    state = client.get("/guidance/state", params={"sessionId": session_id}, label="14. GET /guidance/state")
    require(state.body.get("state") == "WAITING_FOR_BUS", state.label, state.body)
    require(state.body.get("targetBusId") == "BUS_502_NEXT", state.label, state.body)
    print_step(state)

    print("V3 guidance smoke: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SmokeFailure as exc:
        print(f"V3 guidance smoke: FAIL\n{exc}", file=sys.stderr)
        raise SystemExit(1)
