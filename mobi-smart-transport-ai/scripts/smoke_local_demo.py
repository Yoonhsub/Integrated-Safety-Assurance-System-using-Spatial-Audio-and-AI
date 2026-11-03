"""Opt-in integration checks against loopback emulators. Never print tokens."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import httpx

from local_demo import ACCOUNTS, PASSWORD, PROJECT, configure_environment

API = "http://127.0.0.1:8001"
AUTH = "http://127.0.0.1:9099"
DB = "http://127.0.0.1:9000"


def verify() -> list[dict]:
    configure_environment()
    from firebase_admin import auth
    from app.security import firebase_auth_app
    results = []
    tokens = {}
    refresh = {}
    app = firebase_auth_app()
    with httpx.Client(timeout=15) as client:
        def check(name, response, status):
            passed = response.status_code == status
            results.append({"check": name, "passed": passed, "expected": status, "actual": response.status_code})
            if not passed:
                raise AssertionError(f"{name}: expected {status}, got {response.status_code}")
            return response.json() if response.content else None

        health = check("backend health", client.get(API + "/health"), 200)
        if health.get("environment") != "local-demo":
            raise AssertionError("Wrong backend environment; refusing to mutate")
        for uid, *_ in ACCOUNTS:
            response = client.post(AUTH + "/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-local-api-key",
                                   json={"email": f"{uid}@example.test", "password": PASSWORD, "returnSecureToken": True})
            data = check(f"login {uid}", response, 200)
            tokens[uid] = data["idToken"]
            refresh[uid] = data["refreshToken"]

        def request(method, path, user=None, **kwargs):
            headers = {"Authorization": f"Bearer {tokens[user]}"} if user else {}
            return client.request(method, API + path, headers=headers, **kwargs)

        p, other, driver, wrong = [row[0] for row in ACCOUNTS]
        payload = {"userId": p, "stopId": "mock-stop-001", "routeId": "MOCK-502", "busNo": "502"}
        check("unauthenticated blocked", request("POST", "/ride-requests", json=payload), 401)
        check("invalid token blocked", client.post(API + "/ride-requests", headers={"Authorization": "Bearer invalid"}, json=payload), 401)
        check("forged user blocked", request("POST", "/ride-requests", other, json=payload), 403)
        created = check("passenger creates assigned request", request("POST", "/ride-requests", p, json=payload), 200)
        rid = created["requestId"]
        if created["targetDriverId"] != "demo-driver-502":
            raise AssertionError("Incorrect local dispatch")
        path = f"/ride-requests/{rid}"
        check("other passenger blocked", request("GET", path, other), 403)
        check("other driver blocked", request("GET", path, wrong), 403)
        check("passenger driver-list blocked", request("GET", "/drivers/demo-driver-502/ride-requests", p), 403)
        listed = check("assigned driver list", request("GET", "/drivers/demo-driver-502/ride-requests", driver), 200)
        if rid not in {row['requestId'] for row in listed['requests']}:
            raise AssertionError("Request missing from driver list")
        check("other driver update blocked", request("PATCH", path + "/status", wrong, json={"status": "ACCEPTED"}), 403)
        check("assigned driver accepts", request("PATCH", path + "/status", driver, json={"status": "ACCEPTED"}), 200)
        current = check("passenger observes accepted", request("GET", path, p), 200)
        if current["status"] != "ACCEPTED": raise AssertionError("Acceptance not persisted")
        check("passenger cancels", request("PATCH", path + "/status", p, json={"status": "CANCELLED"}), 200)
        current = check("driver observes cancellation", request("GET", path, driver), 200)
        if current['status'] != 'CANCELLED': raise AssertionError("Cancellation not persisted")
        refreshed = check("emulator token refresh", client.post(AUTH + "/securetoken.googleapis.com/v1/token?key=demo-local-api-key",
                          data={"grant_type": "refresh_token", "refresh_token": refresh[p]}), 200)
        tokens[p] = refreshed["id_token"]
        check("refreshed token accepted", request("GET", path, p), 200)
        session = check("server creates owned session", request("POST", "/guidance/session", p, json={"wakeWord": "모비"}), 200)
        check("foreign guidance session blocked", request("GET", "/guidance/state", other, params={"sessionId": session["sessionId"]}), 403)
        check("passenger cannot forge guidance event", request("POST", "/guidance/event", p,
              json={"sessionId": session["sessionId"], "event": "WAITING_FOR_BUS", "payload": {}}), 403)

        from websockets.sync.client import connect
        from websockets.exceptions import InvalidStatus, ConnectionClosed
        ws_url = "ws://127.0.0.1:8001/agent/converse/live"
        try:
            with connect(ws_url, open_timeout=5):
                raise AssertionError("Unauthenticated websocket accepted")
        except InvalidStatus as error:
            if error.response.status_code != 403: raise AssertionError("Unexpected websocket rejection") from None
        results.append({"check": "unauthenticated browser-style websocket rejected", "passed": True})
        with connect(ws_url, additional_headers={"Authorization": f"Bearer {tokens[p]}"}, open_timeout=5) as ws:
            ws.send("{}")  # validation error proves authenticated transport without calling an external model
            message = json.loads(ws.recv(timeout=5))
            if message.get('type') != 'error': raise AssertionError("Expected controlled validation error")
        results.append({"check": "authenticated websocket transport", "passed": True})
        with connect(ws_url, additional_headers={"Authorization": f"Bearer {tokens[other]}"}, open_timeout=5) as ws:
            ws.send(json.dumps({"utterance": "안내", "sessionId": session['sessionId'], "mode": "mock"}))
            try:
                ws.recv(timeout=5)
                raise AssertionError("Foreign websocket session accepted")
            except ConnectionClosed as error:
                if error.rcvd is None or error.rcvd.code != 1008: raise AssertionError("Unexpected session rejection") from None
        results.append({"check": "foreign websocket session rejected", "passed": True})

        def database(method, path, user, body=None):
            return client.request(method, DB + path + ".json", params={"ns": PROJECT + "-default-rtdb", "auth": tokens[user]},
                                  **({"json": body} if body is not None else {}))
        location = {"lat": 36.6359, "lng": 127.4596, "updatedAt": "2026-10-11T00:00:00Z"}
        check("RTDB own passenger location", database("PUT", f"/users/{p}/currentLocation", p, location), 200)
        check("RTDB other user denied", database("PUT", f"/users/{other}/currentLocation", p, location), 401)
        check("RTDB extra fields denied", database("PUT", f"/users/{p}/currentLocation", p, {**location, "role": "admin"}), 401)
        check("RTDB invalid coordinate denied", database("PUT", f"/users/{p}/currentLocation", p, {**location, "lat": 100}), 401)
        check("RTDB sensitive reads denied", database("GET", "/rideRequests", p), 401)
        check("RTDB assigned driver location", database("PUT", "/drivers/demo-driver-502/currentLocation", driver, location), 200)
        check("RTDB other driver denied", database("PUT", "/drivers/demo-driver-502/currentLocation", wrong, location), 401)
        try:
            auth.update_user(other, disabled=True, app=app)
            check("disabled account blocked", request("GET", path, other), 401)
        finally:
            auth.update_user(other, disabled=False, app=app)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    results = verify()
    args.output.write_text(json.dumps({"project": PROJECT, "scope": "real local emulators; no BLE/YOLO hardware", "checks": results}, indent=2), encoding="utf-8")
    print(f"PASS: {len(results)} local emulator integration checks; report: {args.output}")


if __name__ == "__main__":
    main()
