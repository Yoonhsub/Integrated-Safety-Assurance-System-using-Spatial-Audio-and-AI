#!/usr/bin/env python3
"""V3 버스 탑승 안내 에이전트 smoke test."""
from __future__ import annotations

import os
import sys

import httpx

BASE_URL = os.getenv("V3_API_BASE_URL", "http://127.0.0.1:8000")
SESSION_ID = "smoke-session-v3"

PASS = "\033[92m[PASS]\033[0m"
FAIL = "\033[91m[FAIL]\033[0m"

failures: list[str] = []


def check(step: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"{PASS} {step}")
    else:
        print(f"{FAIL} {step} — {detail}")
        failures.append(step)


def post(path: str, body: dict) -> dict:
    r = httpx.post(f"{BASE_URL}{path}", json=body, timeout=10)
    r.raise_for_status()
    return r.json()


def get(path: str, params: dict | None = None) -> dict:
    r = httpx.get(f"{BASE_URL}{path}", params=params, timeout=10)
    r.raise_for_status()
    return r.json()


def main() -> None:
    print(f"\n=== V3 Guidance Smoke Test === BASE_URL={BASE_URL}\n")

    # 1. Health
    try:
        h = get("/health")
        check("1. GET /health", h.get("status") == "ok", str(h))
    except Exception as e:
        check("1. GET /health", False, str(e))

    # 2. Create session
    try:
        s = post("/guidance/session", {"sessionId": SESSION_ID})
        check("2. POST /guidance/session", s.get("sessionId") == SESSION_ID, str(s))
    except Exception as e:
        check("2. POST /guidance/session", False, str(e))

    # 3. FIND_ROUTE converse
    try:
        r = post("/agent/converse", {
            "sessionId": SESSION_ID,
            "utterance": "자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?",
            "lat": 36.6282,
            "lng": 127.4562,
        })
        check("3. POST /agent/converse FIND_ROUTE", r.get("intent") == "FIND_ROUTE", str(r.get("intent")))
        check("3b. guidanceState=ROUTE_RECOMMENDED", r.get("guidanceState") == "ROUTE_RECOMMENDED", str(r.get("guidanceState")))
        check("3c. 502 in message", "502" in r.get("message", ""), r.get("message"))
    except Exception as e:
        check("3. POST /agent/converse FIND_ROUTE", False, str(e))

    # 4. Bus arrivals
    try:
        a = get("/bus/arrivals", {"stopId": "mock-stop-001", "routeNo": "502"})
        arrivals = a.get("arrivals", [])
        check("4. GET /bus/arrivals", len(arrivals) >= 2, str(len(arrivals)))
        check("4b. first arrivalMinutes=6", arrivals[0]["arrivalMinutes"] == 6 if arrivals else False)
    except Exception as e:
        check("4. GET /bus/arrivals", False, str(e))

    # 5. GET_BUS_ARRIVAL converse
    try:
        r = post("/agent/converse", {
            "sessionId": SESSION_ID,
            "utterance": "자비스, 그 버스 언제 와?",
        })
        check("5. GET_BUS_ARRIVAL", r.get("intent") == "GET_BUS_ARRIVAL", str(r.get("intent")))
    except Exception as e:
        check("5. GET_BUS_ARRIVAL", False, str(e))

    # 6. SELECT_ARRIVAL converse
    try:
        r = post("/agent/converse", {
            "sessionId": SESSION_ID,
            "utterance": "응, 6분 뒤 오는 걸로 안내해줘.",
        })
        check("6. SELECT_ARRIVAL", r.get("intent") == "SELECT_ARRIVAL", str(r.get("intent")))
    except Exception as e:
        check("6. SELECT_ARRIVAL", False, str(e))

    # 7. ARRIVED_AT_STOP
    try:
        r = post("/mock/geofence", {"sessionId": SESSION_ID, "mockStatus": "ARRIVED_AT_STOP"})
        check("7. ARRIVED_AT_STOP", r.get("geofenceStatus") == "SAFE", str(r))
        s = get("/guidance/state", {"sessionId": SESSION_ID})
        check("7b. geofenceArmed=true", s.get("geofenceArmed") is True, str(s.get("geofenceArmed")))
    except Exception as e:
        check("7. ARRIVED_AT_STOP", False, str(e))

    # 8. LEFT_WAITING_AREA
    try:
        r = post("/mock/geofence", {"sessionId": SESSION_ID, "mockStatus": "LEFT_WAITING_AREA"})
        check("8. LEFT_WAITING_AREA WARNING", r.get("geofenceStatus") == "WARNING", str(r.get("geofenceStatus")))
    except Exception as e:
        check("8. LEFT_WAITING_AREA", False, str(e))

    # 9. WRONG_BUS_NEAR beacons
    try:
        r = post("/mock/beacons", {
            "sessionId": SESSION_ID,
            "beacons": [
                {"busId": "BUS_1", "routeNo": "511", "distanceLevel": "near", "rssi": -45, "relativePosition": "front"},
                {"busId": "BUS_2", "routeNo": "502", "distanceLevel": "mid", "rssi": -63, "relativePosition": "rear"},
            ],
        })
        check("9. WRONG_BUS_NEAR", r.get("decision") == "WRONG_BUS_NEAR", str(r.get("decision")))
    except Exception as e:
        check("9. WRONG_BUS_NEAR beacons", False, str(e))

    # 10. ASK_CAN_BOARD_CURRENT_BUS
    try:
        r = post("/agent/converse", {
            "sessionId": SESSION_ID,
            "utterance": "자비스, 지금 앞에 온 버스 타도 돼?",
        })
        check("10. ASK_CAN_BOARD_CURRENT_BUS", r.get("intent") == "ASK_CAN_BOARD_CURRENT_BUS", str(r.get("intent")))
        check("10b. negative answer", "아니요" in r.get("message", ""), r.get("message"))
    except Exception as e:
        check("10. ASK_CAN_BOARD_CURRENT_BUS", False, str(e))

    # 11. TARGET_BUS_NEAR
    try:
        r = post("/mock/beacons", {
            "sessionId": SESSION_ID,
            "beacons": [
                {"busId": "BUS_2", "routeNo": "502", "distanceLevel": "near", "rssi": -50, "relativePosition": "front"},
            ],
        })
        check("11. TARGET_BUS_NEAR", r.get("decision") == "TARGET_BUS_NEAR", str(r.get("decision")))
    except Exception as e:
        check("11. TARGET_BUS_NEAR", False, str(e))

    # 12. BUS_PASSED
    try:
        r = post("/mock/bus-event", {"sessionId": SESSION_ID, "event": "BUS_PASSED"})
        check("12. BUS_PASSED→BOARDING_CONFIRMATION", r.get("guidanceState") == "BOARDING_CONFIRMATION", str(r))
    except Exception as e:
        check("12. BUS_PASSED", False, str(e))

    # 13. REPORT_MISSED_BUS
    try:
        r = post("/agent/converse", {
            "sessionId": SESSION_ID,
            "utterance": "자비스, 나 못 탔어.",
        })
        check("13. REPORT_MISSED_BUS", r.get("intent") == "REPORT_MISSED_BUS", str(r.get("intent")))
        check("13b. WAITING_FOR_BUS", r.get("guidanceState") == "WAITING_FOR_BUS", str(r.get("guidanceState")))
        check("13c. next bus in message", "분" in r.get("message", ""), r.get("message"))
    except Exception as e:
        check("13. REPORT_MISSED_BUS", False, str(e))

    # 14. GET final state
    try:
        s = get("/guidance/state", {"sessionId": SESSION_ID})
        check("14. GET /guidance/state", s.get("sessionId") == SESSION_ID, str(s))
    except Exception as e:
        check("14. GET /guidance/state", False, str(e))

    print(f"\n{'='*50}")
    if failures:
        print(f"FAILED: {len(failures)} steps — {failures}")
        sys.exit(1)
    else:
        print(f"ALL PASSED ({14} steps)")
    print('='*50)


if __name__ == "__main__":
    main()
