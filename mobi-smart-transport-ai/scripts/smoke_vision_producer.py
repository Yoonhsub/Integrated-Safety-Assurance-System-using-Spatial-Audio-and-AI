"""Opt-in actual Auth/RTDB Emulator integration; never prints ID tokens."""
import argparse
import json
import secrets
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

import httpx

from local_demo import configure_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-url", help="Optional actual HTTP backend, loopback only")
    parser.add_argument("--report", type=Path, help="Write non-secret integration results")
    parser.add_argument("--restart-checkpoint", type=Path, help="Opt-in: wait for owned backend restart, no credentials saved")
    args = parser.parse_args()
    if args.restart_checkpoint and not args.backend_url:
        parser.error("restart-checkpoint requires an actual HTTP backend")
    if args.backend_url:
        url = urlsplit(args.backend_url)
        if (url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port
                or url.username or url.password or url.path not in ("", "/") or url.query or url.fragment):
            parser.error("backend-url must be http://127.0.0.1:<port>")
    configure_environment()
    from app.local_emulator import validate_local_emulators
    validate_local_emulators()
    from firebase_admin import auth
    from fastapi.testclient import TestClient
    from app.security import firebase_auth_app
    from app.services.firebase_client import get_firebase_client
    from app.services.v3_guidance_store import v3_guidance_store

    firebase = firebase_auth_app()
    storage = get_firebase_client()
    assert storage.initialize() and not storage.using_mock
    users, sessions, tokens = {}, [], {}
    passed = 0
    checks = []
    created_cameras = {}

    def check(condition, name=None):
        nonlocal passed
        assert condition, f"Integration check {passed + 1} failed"
        passed += 1
        checks.append({"name": name or f"check-{passed}", "result": "PASS"})

    try:
        for label, role in (("operator", "admin"), ("producer", "vision_producer"),
                            ("other", "vision_producer"), ("alice", "passenger"),
                            ("bob", "passenger"), ("driver", "driver")):
            password = secrets.token_urlsafe(24)
            user = auth.create_user(email=f"vision-{uuid4().hex}@example.test", password=password, app=firebase)
            users[label] = user.uid
            claims = {"mobi_role": role}
            if role == "driver": claims["mobi_driver_id"] = "test-fleet"
            auth.set_custom_user_claims(user.uid, claims, app=firebase)
            login = httpx.post("http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword",
                               params={"key": "demo-local"}, json={"email": user.email, "password": password,
                                                                   "returnSecureToken": True}, timeout=5)
            login.raise_for_status()
            tokens[label] = {"Authorization": "Bearer " + login.json()["idToken"]}
        if args.backend_url:
            context = httpx.Client(base_url=args.backend_url, timeout=10)
        else:
            from app.main import app
            from app.api.routes import vision_v2
            from app.services.vision_binding_service import VisionBindingService
            assert not app.dependency_overrides, "No mock auth overrides allowed"
            vision_v2.vision_binding_service = VisionBindingService()
            context = TestClient(app)
        with context as client:
            for label in ("alice", "bob"):
                r = client.post("/guidance/session", headers=tokens[label], json={})
                check(r.status_code == 200)
                sessions.append(r.json()["sessionId"])
            check(storage.get(f"/v3GuidanceSessions/{sessions[0]}") is not None)
            camera_id = "smoke-" + uuid4().hex
            r = client.put(f"/ai-vision/v2/cameras/{camera_id}", headers=tokens["operator"],
                           json={"producerId": users["producer"], "sourceType": "live"})
            check(r.status_code == 200)
            body = {"cameraId": camera_id, "sessionId": sessions[0]}
            r = client.post("/ai-vision/v2/bindings", headers=tokens["operator"], json=body)
            check(r.status_code == 201)
            binding = r.json()
            created_cameras[camera_id] = binding["bindingId"]
            payload = {k: binding[k] for k in ("bindingId", "cameraId", "producerId", "sessionId", "cameraEpoch", "sourceType")}
            capture_time = datetime.now(timezone.utc).isoformat()
            payload.update(envelopeVersion="2.0.0", visionEventId=str(uuid4()), frameIndex=10,
                           capturedAt=capture_time, detectionResult={
                               "schemaVersion": "1.0.0", "source": "webcam", "status": "ok",
                               "frameId": str(uuid4()), "capturedAt": capture_time,
                               "modelInfo": {"provider": "mock", "name": "no-weight-fixture"}, "detections": []})
            def new_fixture(event, index=None, age=0):
                # A newly generated synthetic frame, never retimestamp an actual image.
                value = json.loads(json.dumps(event))
                timestamp = (datetime.now(timezone.utc) - timedelta(seconds=age)).isoformat()
                value.update(visionEventId=str(uuid4()), capturedAt=timestamp,
                             frameIndex=event["frameIndex"] if index is None else index)
                value["detectionResult"].update(frameId=str(uuid4()), capturedAt=timestamp)
                return value

            def send(headers, event=payload):
                return client.post("/ai-vision/v2/events", headers=headers, json=event)
            good = send(tokens["producer"])
            check(good.status_code == 202, "actual-v2-http-202")
            check(good.json()["accepted"] is True, "accepted-true")
            check(good.json()["stored"] is False, "stored-false")
            check(good.json()["guidanceEligible"] is False, "guidance-disabled")
            check(good.json()["freshnessVerified"] is False, "freshness-not-verified")
            repeated = send(tokens["producer"])
            check(repeated.status_code == 202 and repeated.json() == good.json(), "duplicate-event-original-response")
            eleven = new_fixture(payload, 11)
            check(send(tokens["producer"], eleven).status_code == 202, "next-frame-accepted")
            check(send(tokens["producer"], new_fixture(payload, 10)).status_code == 409, "reverse-frame-rejected")
            check(send(tokens["producer"], new_fixture(payload, 12, age=60)).status_code == 409, "old-frame-rejected")
            check(send(tokens["producer"], new_fixture(payload, 12, age=-60)).status_code == 409, "future-frame-rejected")
            status = client.get(f"/ai-vision/v2/cameras/{camera_id}/state", headers=tokens["producer"])
            check(status.status_code == 200 and status.json()["lastFrameIndex"] == 11, "rejected-inputs-do-not-advance-watermark")
            check(status.json()["freshnessVerified"] is False, "client-clock-not-attested")
            # Default demo TTL/loss limits are not safety-calibrated. Query-time expiry
            # must occur with no new input; do not change production configuration.
            import os
            ttl = float(os.getenv("MOBI_VISION_OBSERVATION_TTL_SEC", "3"))
            loss = float(os.getenv("MOBI_VISION_CONNECTION_TIMEOUT_SEC", "5"))
            if max(ttl, loss) > 10:
                raise RuntimeError("Opt-in smoke expects local test limits <=10 seconds")
            time.sleep(ttl + 0.1)
            status = client.get(f"/ai-vision/v2/cameras/{camera_id}/state", headers=tokens["producer"])
            check(status.json()["observationStatus"] == "expired", "query-expires-without-new-frame")
            time.sleep(max(0, loss - ttl) + 0.1)
            status = client.get(f"/ai-vision/v2/cameras/{camera_id}/state", headers=tokens["producer"])
            check(status.json()["connectionStatus"] == "lost", "connection-loss-without-new-frame")
            check(send(tokens["producer"], new_fixture(payload, 12)).status_code == 202, "new-frame-resumes-after-loss")
            from app.services.vision_event_ledger import producer_path, event_key
            import socket
            root_path = producer_path(users["producer"])
            lost_request = new_fixture(payload, 20)
            raw_body = json.dumps(lost_request).encode("utf-8")
            url = urlsplit(args.backend_url) if args.backend_url else None
            if url:
                # Intentionally close without reading the HTTP response. Tokens
                # stay only in memory and are never printed or written to files.
                with socket.create_connection((url.hostname, url.port), timeout=5) as sock:
                    message = ("POST /ai-vision/v2/events HTTP/1.1\r\n"
                               f"Host: 127.0.0.1:{url.port}\r\n"
                               f"Authorization: {tokens['producer']['Authorization']}\r\n"
                               "Content-Type: application/json\r\n"
                               f"Content-Length: {len(raw_body)}\r\nConnection: close\r\n\r\n").encode("ascii") + raw_body
                    sock.sendall(message)
                    sock.shutdown(socket.SHUT_WR)
                deadline = time.monotonic() + 10
                record = None
                while time.monotonic() < deadline:
                    row = storage.get(root_path) or {}
                    record = row.get("events", {}).get(event_key(lost_request["visionEventId"]))
                    if record: break
                    time.sleep(0.1)
                check(record is not None, "http-response-loss-commit-confirmed")
                with ThreadPoolExecutor(4) as pool:
                    retries = list(pool.map(lambda _: send(tokens["producer"], lost_request), range(8)))
                check(all(r.status_code == 202 and r.json() == record["response"] for r in retries), "concurrent-http-retries-one-original-receipt")
                after = storage.get(root_path)
                check(after["streams"][payload["bindingId"]]["frameIndex"] == 20, "atomic-receipt-watermark")
                conflict = json.loads(json.dumps(lost_request))
                conflict["detectionResult"]["modelInfo"]["name"] = "different-model"
                check(send(tokens["producer"], conflict).status_code == 409, "same-event-different-payload")
                check(send(tokens["producer"], dict(reversed(list(lost_request.items())))).json() == record["response"], "json-order-stable")
                check(send(tokens["producer"], dict(lost_request, visionEventId=str(uuid4()))).status_code == 409, "same-index-new-event-rejected")
                snapshot = client.get(f"/ai-vision/v2/cameras/{camera_id}/state", headers=tokens["producer"]).json()
                time.sleep(ttl + 0.1)
                check(send(tokens["producer"], lost_request).json() == record["response"], "old-event-retry-after-ttl")
                state = client.get(f"/ai-vision/v2/cameras/{camera_id}/state", headers=tokens["producer"]).json()
                check(state["observationStatus"] == "expired" and state["lastReceivedAt"] == snapshot["lastReceivedAt"], "retry-does-not-refresh-ttl")

            check(send({}).status_code == 401)
            check(send({"Authorization": "Bearer invalid"}).status_code == 401)
            for label in ("alice", "driver", "operator", "other"):
                check(send(tokens[label]).status_code == 403)
            check(send(tokens["producer"], dict(payload, sessionId=sessions[1])).status_code == 403)
            check(client.post("/ai-vision/events", headers=tokens["producer"], json={}).status_code == 403)
            with ThreadPoolExecutor(4) as pool:
                bindings = list(pool.map(lambda _: client.post("/ai-vision/v2/bindings",
                    headers=tokens["operator"], json=body), range(4)))
            check(all(r.status_code == 201 for r in bindings))
            outcomes = [send(tokens["producer"], new_fixture(dict(payload, bindingId=r.json()["bindingId"],
                        cameraEpoch=r.json()["cameraEpoch"]))).status_code for r in bindings]
            check(outcomes.count(202) == 1 and outcomes.count(403) == 3)
            check(send(tokens["producer"]).status_code == 403)
            winner = bindings[outcomes.index(202)].json()
            created_cameras[camera_id] = winner["bindingId"]
            active = dict(payload, bindingId=winner["bindingId"], cameraEpoch=winner["cameraEpoch"])
            auth.update_user(users["producer"], disabled=True, app=firebase)
            check(send(tokens["producer"], active).status_code == 401)
            auth.update_user(users["producer"], disabled=False, app=firebase)
            auth.set_custom_user_claims(users["producer"], {"mobi_role": "passenger"}, app=firebase)
            check(send(tokens["producer"], active).status_code == 403)
            auth.set_custom_user_claims(users["producer"], {"mobi_role": "vision_producer"}, app=firebase)
            check(client.post("/guidance/reset", headers=tokens["alice"], json={
                "sessionId": sessions[0], "event": "RESET", "payload": {}}).status_code == 200)
            check(send(tokens["producer"], active).status_code == 403, "session-reset-invalidates-binding")
            # Reconnect to the reset generation, revoke, reconnect again.
            fresh = client.post("/ai-vision/v2/bindings", headers=tokens["operator"], json=body)
            check(fresh.status_code == 201, "reconnect")
            b = fresh.json()
            created_cameras[camera_id] = b["bindingId"]
            active = dict(payload, bindingId=b["bindingId"], cameraEpoch=b["cameraEpoch"])
            check(send(tokens["producer"], new_fixture(active)).status_code == 202, "reconnected-submit")
            r = client.delete(f"/ai-vision/v2/cameras/{camera_id}/bindings/{b['bindingId']}", headers=tokens["operator"])
            check(r.status_code == 204, "explicit-binding-revoke")
            created_cameras.pop(camera_id, None)
            check(send(tokens["producer"], active).status_code == 403, "revoked-binding-rejected")
            fresh = client.post("/ai-vision/v2/bindings", headers=tokens["operator"], json=body)
            check(fresh.status_code == 201)
            b = fresh.json()
            created_cameras[camera_id] = b["bindingId"]
            active = dict(payload, bindingId=b["bindingId"], cameraEpoch=b["cameraEpoch"])
            for event in ("ROUTE_SELECTED", "ARRIVED_AT_STOP", "BOARDING_CONFIRMATION", "BOARDED"):
                r = client.post("/guidance/event", headers=tokens["operator"], json={
                    "sessionId": sessions[0], "event": event, "payload": {"routeNo": "502"}})
                check(r.status_code == 200, "guidance-" + event)
            check(send(tokens["producer"], active).status_code == 403, "ended-session-rejected")
            # Replay uses a separate camera and active passenger session.
            replay_camera = "smoke-replay-" + uuid4().hex
            check(client.put(f"/ai-vision/v2/cameras/{replay_camera}", headers=tokens["operator"],
                json={"producerId": users["producer"], "sourceType": "replay"}).status_code == 200)
            r = client.post("/ai-vision/v2/bindings", headers=tokens["operator"],
                json={"cameraId": replay_camera, "sessionId": sessions[1]})
            check(r.status_code == 201)
            b = r.json()
            created_cameras[replay_camera] = b["bindingId"]
            replay = dict(payload, cameraId=replay_camera, sessionId=sessions[1], sourceType="replay",
                          bindingId=b["bindingId"], cameraEpoch=b["cameraEpoch"], visionEventId=str(uuid4()),
                          detectionResult=dict(payload["detectionResult"], source="video_file"))
            replay["capturedAt"] = "2000-01-01T00:00:00Z"
            replay["detectionResult"]["capturedAt"] = replay["capturedAt"]
            replay_response = send(tokens["producer"], replay)
            check(replay_response.status_code == 202, "replay-http-202")
            check(not replay_response.json()["guidanceEligible"] and not replay_response.json()["stored"], "replay-not-live")
            state = client.get("/guidance/state", headers=tokens["bob"], params={"sessionId": sessions[1]})
            check(state.status_code == 200 and state.json()["state"] == "IDLE", "replay-preserves-guidance")
            for camera, binding_id in created_cameras.items():
                check(client.delete(f"/ai-vision/v2/cameras/{camera}/bindings/{binding_id}", headers=tokens["operator"]).status_code == 204)
            other_camera = "smoke-other-" + uuid4().hex
            check(client.put(f"/ai-vision/v2/cameras/{other_camera}", headers=tokens["operator"],
                json={"producerId": users["other"], "sourceType": "live"}).status_code == 200)
            r = client.post("/ai-vision/v2/bindings", headers=tokens["operator"], json={"cameraId": other_camera, "sessionId": sessions[1]})
            check(r.status_code == 201)
            other_binding = r.json()
            other_event = new_fixture(dict(payload, producerId=users["other"], cameraId=other_camera,
                sessionId=sessions[1], bindingId=other_binding["bindingId"], cameraEpoch=other_binding["cameraEpoch"]), 0)
            other_event["visionEventId"] = payload["visionEventId"]
            check(send(tokens["other"], other_event).status_code == 202, "different-producer-same-event-id")
            check(client.delete(f"/ai-vision/v2/cameras/{other_camera}/bindings/{other_binding['bindingId']}", headers=tokens["operator"]).status_code == 204)
            if args.restart_checkpoint:
                r = client.post("/guidance/session", headers=tokens["alice"], json={})
                check(r.status_code == 200)
                sessions.append(r.json()["sessionId"])
                before_restart_camera = "smoke-before-restart-" + uuid4().hex
                check(client.put(f"/ai-vision/v2/cameras/{before_restart_camera}", headers=tokens["operator"],
                    json={"producerId": users["producer"], "sourceType": "live"}).status_code == 200)
                r = client.post("/ai-vision/v2/bindings", headers=tokens["operator"], json={"cameraId": before_restart_camera, "sessionId": sessions[-1]})
                check(r.status_code == 201)
                before_binding = r.json()
                restart_payload = new_fixture(dict(payload, cameraId=before_restart_camera, sessionId=sessions[-1],
                    bindingId=before_binding["bindingId"], cameraEpoch=before_binding["cameraEpoch"]), 0)
                restart_response = send(tokens["producer"], restart_payload)
                check(restart_response.status_code == 202, "active-binding-before-backend-restart")
                check(send(tokens["producer"], restart_payload).json() == restart_response.json(), "active-duplicate-before-backend-restart")
                marker = args.restart_checkpoint
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.with_suffix(".ready").write_text("Ready for owned backend restart; no secrets in this file", encoding="utf-8")
                deadline = time.monotonic() + 180
                while not marker.with_suffix(".continue").exists():
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Owned backend restart was not confirmed")
                    time.sleep(0.2)
                check(send(tokens["producer"], restart_payload).status_code == 403, "backend-restart-old-binding-denied")
                check(storage.get(root_path)["events"][event_key(restart_payload["visionEventId"])]["response"] == restart_response.json(), "receipt-survives-backend-restart")
                r = client.post("/guidance/session", headers=tokens["alice"], json={})
                check(r.status_code == 200)
                sessions.append(r.json()["sessionId"])
                restart_camera = "smoke-restart-" + uuid4().hex
                check(client.put(f"/ai-vision/v2/cameras/{restart_camera}", headers=tokens["operator"],
                    json={"producerId": users["producer"], "sourceType": "live"}).status_code == 200)
                r = client.post("/ai-vision/v2/bindings", headers=tokens["operator"], json={"cameraId": restart_camera, "sessionId": sessions[-1]})
                check(r.status_code == 201)
                b = r.json()
                restarted = new_fixture(dict(payload, cameraId=restart_camera, sessionId=sessions[-1], bindingId=b["bindingId"], cameraEpoch=b["cameraEpoch"]), 0)
                restarted["visionEventId"] = restart_payload["visionEventId"]
                check(send(tokens["producer"], restarted).status_code == 409, "new-binding-cannot-reuse-old-event-id")
                restarted["visionEventId"] = str(uuid4())
                check(send(tokens["producer"], restarted).status_code == 202, "new-event-after-restart")
                check(client.delete(f"/ai-vision/v2/cameras/{restart_camera}/bindings/{b['bindingId']}", headers=tokens["operator"]).status_code == 204)
            if args.report:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_text(json.dumps({"project": "demo-mobi-local", "transport": "actual-http" if args.backend_url else "in-process-testclient",
                    "auth": "actual-auth-emulator", "session_mirror": "actual-rtdb-emulator", "binding_store": "process-memory",
                    "mock_auth": False, "mock_transport": False, "passed": passed, "checks": checks}, indent=2), encoding="utf-8")
        print(f"Vision Producer Auth/RTDB Emulator integration: {passed} PASS (no model or Live delivery)")
    finally:
        for sid in sessions:
            storage.delete(f"/v3GuidanceSessions/{sid}")
        from app.services.vision_event_ledger import producer_path
        for uid in users.values():
            storage.delete(producer_path(uid))
            auth.delete_user(uid, app=firebase)
        v3_guidance_store.clear()


if __name__ == "__main__":
    main()
