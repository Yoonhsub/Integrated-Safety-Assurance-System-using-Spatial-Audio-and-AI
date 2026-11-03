"""Opt-in real Auth/HTTP/RTDB creation deduplication checks; loopback demo only."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
from threading import Barrier
from uuid import uuid4

import httpx

from local_demo import PASSWORD, configure_environment


def verify():
    configure_environment()
    from app.local_emulator import validate_local_emulators
    from app.services.firebase_client import FirebaseClient
    validate_local_emulators()
    database = FirebaseClient()
    ids = set()
    checks = []
    with httpx.Client(timeout=15) as client:
        api = "http://127.0.0.1:8001"
        assert client.get(api + "/health").json()["environment"] == "local-demo"
        tokens = {}
        for uid in ("demo-passenger-a", "demo-passenger-b"):
            response = client.post("http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-local-api-key",
                                   json={"email": uid + "@example.test", "password": PASSWORD, "returnSecureToken": True})
            assert response.status_code == 200
            tokens[uid] = response.json()["idToken"]
        key = uuid4().hex

        def post(k=key, uid="demo-passenger-a", **changes):
            body = {"userId": uid, "stopId": "mock-stop-001", "routeId": "MOCK-502", "busNo": "502", **changes}
            return client.post(api + "/ride-requests", headers={"Authorization": "Bearer " + tokens[uid], "Idempotency-Key": k}, json=body)

        def check(name, condition):
            assert condition, name
            checks.append({"check": name, "passed": True})

        try:
            barrier = Barrier(6)

            def parallel(_):
                barrier.wait(timeout=10)
                return post()

            with ThreadPoolExecutor(max_workers=6) as pool:
                replies = list(pool.map(parallel, range(6)))
            for reply in replies:
                if reply.status_code == 200:
                    ids.add(reply.json()["requestId"])
            check("six concurrent same-key posts succeed", all(r.status_code == 200 for r in replies))
            check("one request ID across concurrent posts", len(ids) == 1)
            rid = next(iter(ids))
            check("same createdAt across concurrent replies", len({r.json()["createdAt"] for r in replies}) == 1)
            replay = post()  # Original response could have been lost; client repeats its action key.
            check("lost-response retry returns same ID", replay.status_code == 200 and replay.json()["requestId"] == rid)
            check("internal metadata excluded from API", "_creation" not in replay.json())
            mismatch = post(stopId="different-stop")
            check("same key different payload rejected", mismatch.status_code == 409)
            other = post(uid="demo-passenger-b")
            if other.status_code == 200:
                ids.add(other.json()["requestId"])
            check("same key different UID is isolated", other.status_code == 200 and other.json()["requestId"] != rid)
            spoof = post(userId="demo-passenger-b")
            check("forged user rejected", spoof.status_code == 403)
            cancel = client.patch(api + f"/ride-requests/{rid}/status", headers={"Authorization": "Bearer " + tokens['demo-passenger-a']}, json={"status": "CANCELLED"})
            check("owner cancellation succeeds", cancel.status_code == 200)
            replay = post()
            check("old key after cancellation returns cancelled request", replay.status_code == 200 and replay.json()["requestId"] == rid and replay.json()["status"] == "CANCELLED")
            new = post(uuid4().hex)
            if new.status_code == 200:
                ids.add(new.json()["requestId"])
            check("new action after cancellation allowed", new.status_code == 200 and new.json()["requestId"] != rid)
            check("malformed key rejected", post("short").status_code == 400)
            check("missing authentication rejected", client.post(api + "/ride-requests", headers={"Idempotency-Key": key}, json={"userId": "demo-passenger-a", "stopId": "s", "routeId": "r", "busNo": "b"}).status_code == 401)
            check("notification claim durably retained", database.get("/rideRequests/" + rid)["_creation"]["notification"]["state"] in {"accepted", "failed", "unknown", "claimed"})
        finally:
            for rid in ids:
                database.delete("/rideRequests/" + rid)
    return checks


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    checks = verify()
    args.output.write_text(json.dumps({"scope": "real local Auth/HTTP/RTDB; FCM not delivered to hardware", "checks": checks}, indent=2), encoding="utf-8")
    print(f"PASS: {len(checks)} authenticated idempotency checks")
