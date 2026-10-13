"""Actual loopback Auth/RTDB/HTTP client smoke. Disposable own accounts only."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import secrets
import sys
import time
from uuid import uuid4

import httpx
from local_demo import configure_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-url", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--restart-checkpoint", type=Path)
    parser.add_argument("--rtdb-failure-marker", type=Path, help="Opt-in owned backend network fault harness only")
    args = parser.parse_args()
    configure_environment()
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from ai_vision.pipelines.vision_producer_client import EmulatorProducerAuth, ProducerError, RetryPolicy, VisionEvent, VisionProducerClient, _loopback
    from app.security import firebase_auth_app
    from app.services.firebase_client import get_firebase_client
    from app.services.vision_event_ledger import producer_path, event_key
    from firebase_admin import auth
    _loopback(args.backend_url)
    app, storage = firebase_auth_app(), get_firebase_client()
    assert storage.initialize() and not storage.using_mock
    accounts, sessions, checks, producers = [], [], [], []

    def check(value, name):
        if not value: raise RuntimeError("Failed: " + name)
        checks.append(name)

    def expect(fn, status, name):
        try: fn()
        except ProducerError as exc:
            check(exc.status == status, name)
        else: raise RuntimeError("Expected rejection: " + name)

    try:
        identities = {}
        for label, role in (("admin", "admin"), ("passenger", "passenger"),
                            ("vision_producer", "vision_producer"), ("foreign", "vision_producer")):
            password = secrets.token_urlsafe(24)
            user = auth.create_user(email=f"client-{uuid4().hex}@example.test", password=password, app=app)
            accounts.append(user.uid)
            auth.set_custom_user_claims(user.uid, {"mobi_role": role}, app=app)
            login = EmulatorProducerAuth(project_id="demo-mobi-local")
            producers.append(login)
            login.login(user.email, password)
            identities[label] = login
            check(login.uid == user.uid, "actual-login-" + label)
        producer = identities["vision_producer"]
        first = producer.token()
        refreshed = producer.token(force_refresh=True)
        check(isinstance(refreshed, str) and bool(refreshed), "actual-refresh-token-exchange")
        # Emulator can issue identical tokens within one second; verify through Admin SDK.
        check(auth.verify_id_token(refreshed, app=app)["uid"] == producer.uid, "actual-refreshed-id-token-verification")
        with httpx.Client(base_url=args.backend_url, timeout=10, trust_env=False) as http:
            admin = {"Authorization": "Bearer " + identities["admin"].token()}
            passenger = {"Authorization": "Bearer " + identities["passenger"].token()}

            def new_binding():
                response = http.post("/guidance/session", headers=passenger, json={})
                check(response.status_code == 200, "actual-guidance-session")
                sid = response.json()["sessionId"]
                sessions.append(sid)
                camera = "client-" + uuid4().hex
                response = http.put(f"/ai-vision/v2/cameras/{camera}", headers=admin,
                                   json={"producerId": producer.uid, "sourceType": "live"})
                check(response.status_code == 200, "actual-admin-camera-registration")
                response = http.post("/ai-vision/v2/bindings", headers=admin, json={"cameraId": camera, "sessionId": sid})
                check(response.status_code == 201, "actual-admin-binding")
                return response.json()

            def make(binding, index=0):
                captured = datetime.now(timezone.utc).isoformat()
                return VisionEvent.create(binding, dict(schemaVersion="1.0.0", source="webcam", status="ok",
                    frameId=str(uuid4()), capturedAt=captured, modelInfo=dict(provider="mock", name="no-weight-fixture"), detections=[]),
                    captured_at=captured, frame_index=index)

            binding = new_binding()
            client = VisionProducerClient(args.backend_url, producer)
            client.attach_binding(binding)
            try:
                event = make(binding)
                result = client.send(event)
                check(result["accepted"] and not any(result[k] for k in
                      ("stored", "guidanceEligible", "freshnessVerified")), "actual-client-202-disabled-flags")
                check(client.send(event) == result, "actual-identical-retry-original-receipt")
                changed = event.payload()
                changed["captureClock"] = "host_read"
                response = http.post("/ai-vision/v2/events", content=json.dumps(changed),
                    headers={"Authorization": "Bearer " + producer.token(), "Content-Type": "application/json"})
                check(response.status_code == 409, "actual-same-id-different-payload-conflict")
                # Client recreation preserves the Envelope, not mutable frame metadata.
                restarted_client = VisionProducerClient(args.backend_url, producer)
                restarted_client.attach_binding(binding)
                check(restarted_client.send(VisionEvent(event.body)) == result, "actual-client-recreation-retry")
                restarted_client.close()
                # Actual invalid token receives 401; one real renewal recovers same body.
                original_token = producer.token
                used = [False]
                def invalid_once(*, force_refresh=False):
                    if not used[0] and not force_refresh:
                        used[0] = True
                        return "invalid-local-token"
                    return original_token(force_refresh=force_refresh)
                producer.token = invalid_once
                next_event = make(binding, 1)
                check(client.send(next_event)["accepted"], "actual-401-real-refresh-same-event")
                producer.token = original_token
                check(http.post("/ai-vision/v2/events", content=next_event.body,
                    headers={"Authorization": "Bearer " + identities["foreign"].token(), "Content-Type": "application/json"}).status_code == 403,
                    "actual-other-producer-cannot-use-camera")
                class LoseResponse(httpx.BaseTransport):
                    def __init__(self):
                        self.real, self.calls, self.first_receipt = httpx.HTTPTransport(), [], None
                    def handle_request(self, request):
                        self.calls.append(request.content)
                        response = self.real.handle_request(request)
                        response.read()
                        if len(self.calls) == 1:
                            self.first_receipt = response.json()
                            response.close()
                            raise httpx.ReadTimeout("Synthetic loss after actual server commit", request=request)
                        return response
                    def close(self): self.real.close()
                lost = LoseResponse()
                retry_client = VisionProducerClient(args.backend_url, producer, transport=lost)
                retry_client.attach_binding(binding)
                retry_event = make(binding, 2)
                check(retry_client.send(retry_event) == lost.first_receipt, "actual-commit-response-loss-recovery")
                check(len(lost.calls) == 2 and lost.calls[0] == lost.calls[1], "actual-response-loss-same-wire-body")
                from concurrent.futures import ThreadPoolExecutor
                with ThreadPoolExecutor(max_workers=4) as pool:
                    duplicate_results = list(pool.map(retry_client.send, [retry_event]*4))
                check(all(r == lost.first_receipt for r in duplicate_results), "actual-concurrent-client-retries-original-receipt")
                retry_client.close()
                if args.rtdb_failure_marker:
                    failure_event = make(binding, 3)
                    failure_client = VisionProducerClient(args.backend_url, producer,
                        policy=RetryPolicy(max_attempts=1, max_elapsed=30, event_max_age=30, request_timeout=10))
                    failure_client.attach_binding(binding)
                    args.rtdb_failure_marker.write_text("Only owned backend ledger network failure", encoding="utf-8")
                    try:
                        try: failure_client.send(failure_event)
                        except ProducerError as exc:
                            check(exc.uncertain and exc.code == "DELIVERY_UNCERTAIN", "actual-sdk-connection-refused-fail-closed")
                        else: raise RuntimeError("Failed RTDB must not accept")
                    finally:
                        args.rtdb_failure_marker.unlink(missing_ok=True)
                    ledger = storage.get(producer_path(producer.uid))
                    check(event_key(failure_event.payload()["visionEventId"]) not in ledger["events"], "actual-rtdb-failure-no-receipt-written")
                    check(failure_client.send(failure_event)["accepted"], "actual-rtdb-network-recovery-same-event")
                    failure_client.close()
                auth.set_custom_user_claims(producer.uid, {"mobi_role": "passenger"}, app=app)
                expect(lambda: client.send(make(binding, 4)), 403, "actual-current-role-revocation-no-retry")
                auth.set_custom_user_claims(producer.uid, {"mobi_role": "vision_producer"}, app=app)
                producer.token(force_refresh=True)
            finally:
                client.close()
            # Expired signed-by-emulator JWT: mutate exp in unsigned emulator token only.
            import base64
            parts = producer.token().split(".")
            claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
            claims["exp"] = int(time.time()) - 3600
            parts[1] = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
            expired = ".".join(parts)
            check(http.post("/ai-vision/v2/events", content=next_event.body,
                            headers={"Authorization": "Bearer " + expired, "Content-Type": "application/json"}).status_code == 401,
                  "actual-emulator-expired-token-401-synthetic-exp")
            check(http.delete(f"/ai-vision/v2/cameras/{binding['cameraId']}/bindings/{binding['bindingId']}",
                              headers=admin).status_code == 204, "actual-binding-revocation")
            denied = VisionProducerClient(args.backend_url, producer, policy=RetryPolicy(event_max_age=180))
            denied.attach_binding(binding)
            expect(lambda: denied.send(next_event), 403, "actual-revoked-binding-retry-denied")
            denied.close()
            if args.restart_checkpoint:
                b = new_binding()
                # Test-only receipt retry horizon; server freshness and Binding
                # gates remain unchanged. This does not make an old frame live.
                c = VisionProducerClient(args.backend_url, producer, policy=RetryPolicy(event_max_age=180))
                c.attach_binding(b)
                e = make(b)
                result = c.send(e)
                marker = args.restart_checkpoint
                marker.with_suffix(".ready").write_text("Owned backend restart requested; no secrets", encoding="utf-8")
                limit = time.monotonic() + 180
                while not marker.with_suffix(".continue").exists():
                    if time.monotonic() > limit: raise RuntimeError("Restart not confirmed")
                    time.sleep(.2)
                expect(lambda: c.send(e), 403, "actual-backend-restart-old-binding-denied")
                record = storage.get(producer_path(producer.uid))["events"][event_key(e.payload()["visionEventId"])]
                check(record["response"] == result, "actual-receipt-persists-across-backend-restart")
                new_b = new_binding()
                c.attach_binding(new_b)
                check(c.send(make(new_b))["accepted"], "actual-new-binding-epoch-after-backend-restart")
                c.close()
            args.report.write_text(json.dumps(dict(passed=len(checks), checks=checks, transport="actual-http",
                auth="actual-auth-emulator", ledger="actual-rtdb-emulator", binding="process-memory",
                limitations=["Expired JWT exp synthetically changed; no one-hour wait",
                             "RTDB fault harness routes only owned backend ledger SDK HTTP to closed loopback port; Emulator remains running",
                             "Response loss injected after actual HTTP 202; not a physical network outage"]), indent=2), encoding="utf-8")
            print(f"Producer Client actual Auth/RTDB/HTTP: {len(checks)} PASS")
    finally:
        for login in producers: login.close()
        for sid in sessions: storage.delete(f"/v3GuidanceSessions/{sid}")
        for uid in accounts:
            storage.delete(producer_path(uid))
            auth.delete_user(uid, app=app)


if __name__ == "__main__":
    main()
