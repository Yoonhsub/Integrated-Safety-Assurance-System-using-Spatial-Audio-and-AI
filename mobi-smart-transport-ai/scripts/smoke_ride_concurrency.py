"""Opt-in authenticated HTTP race checks against the loopback-only local demo."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
from threading import Barrier

import httpx

from local_demo import PASSWORD, configure_environment


def verify() -> list[dict]:
    configure_environment()
    from app.services.firebase_client import FirebaseClient
    from app.local_emulator import validate_local_emulators
    validate_local_emulators()
    api = "http://127.0.0.1:8001"
    auth = "http://127.0.0.1:9099"
    created = []
    results = []
    database = FirebaseClient()
    with httpx.Client(timeout=20) as client:
        health = client.get(api + "/health")
        health.raise_for_status()
        if health.json().get("environment") != "local-demo":
            raise RuntimeError("Refusing mutations outside local-demo")
        tokens = {}
        for user in ("demo-passenger-a", "demo-driver-a", "demo-driver-b"):
            response = client.post(auth + "/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-local-api-key",
                                   json={"email": user + "@example.test", "password": PASSWORD, "returnSecureToken": True})
            if response.status_code != 200:
                raise AssertionError(f"Local login failed: {response.status_code}")
            tokens[user] = response.json()["idToken"]

        def request(method, path, user, **kwargs):
            return client.request(method, api + path,
                                  headers={"Authorization": "Bearer " + tokens[user]}, **kwargs)

        def create():
            response = request("POST", "/ride-requests", "demo-passenger-a", json={
                "userId": "demo-passenger-a", "stopId": "mock-stop-001", "routeId": "MOCK-502", "busNo": "502"})
            assert response.status_code == 200, f"Create failed: {response.status_code}"
            rid = response.json()["requestId"]
            created.append(rid)
            return "/ride-requests/" + rid

        def race(path, commands):
            barrier = Barrier(len(commands))

            def patch(command):
                user, state = command
                barrier.wait(timeout=10)
                return request("PATCH", path + "/status", user, json={"status": state})

            with ThreadPoolExecutor(max_workers=len(commands)) as pool:
                return list(pool.map(patch, commands))

        def record(name, responses, final):
            results.append({"check": name, "passed": True,
                            "http_statuses": [row.status_code for row in responses], "final_status": final})

        try:
            for index in range(10):
                path = create()
                responses = race(path, [("demo-driver-a", "ACCEPTED"), ("demo-passenger-a", "CANCELLED")])
                assert responses[0].status_code in {200, 409}
                assert responses[1].status_code == 200
                final = request("GET", path, "demo-passenger-a").json()["status"]
                assert final == "CANCELLED"
                record(f"accept/cancel race {index + 1}", responses, final)
                stale = request("PATCH", path + "/status", "demo-driver-a", json={"status": "ACCEPTED"})
                assert stale.status_code == 409
                replay = request("PATCH", path + "/status", "demo-passenger-a", json={"status": "CANCELLED"})
                assert replay.status_code == 200
                assert replay.json()["status"] == "CANCELLED"
                record(f"late acceptance / cancellation retry {index + 1}", [stale, replay], "CANCELLED")

            path = create()
            responses = race(path, [("demo-driver-a", "ACCEPTED"), ("demo-driver-a", "ACCEPTED"),
                                    ("demo-driver-b", "ACCEPTED")])
            assert [row.status_code for row in responses] == [200, 200, 403]
            assert responses[0].json()["updatedAt"] == responses[1].json()["updatedAt"]
            record("duplicate acceptance / unassigned driver", responses, "ACCEPTED")
            responses = race(path, [("demo-driver-a", "COMPLETED"), ("demo-passenger-a", "CANCELLED")])
            assert sorted(row.status_code for row in responses) == [200, 409]
            final = request("GET", path, "demo-passenger-a").json()["status"]
            assert final in {"COMPLETED", "CANCELLED"}
            record("completion/cancellation terminal race", responses, final)
        finally:
            # Only unique records created by this invocation, never reset the database.
            for rid in created:
                database.delete("/rideRequests/" + rid)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    results = verify()
    args.output.write_text(json.dumps({"scope": "real local Auth/RTDB and HTTP API; no hardware",
                                       "checks": results}, indent=2), encoding="utf-8")
    print(f"PASS: {len(results)} authenticated local concurrency checks")


if __name__ == "__main__":
    main()
