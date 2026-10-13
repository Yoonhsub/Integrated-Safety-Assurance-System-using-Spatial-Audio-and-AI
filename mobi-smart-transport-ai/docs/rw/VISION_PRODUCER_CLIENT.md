# Local Python Vision v2 Producer Client

`ai_vision/pipelines/vision_producer_client.py` is independent of backend imports,
the legacy SafetyInterpretation client, Streaming and Flutter. It submits the
existing DetectionResult inside the existing v2 Envelope. No safety event storage,
passenger delivery or boarding permission is enabled. All success responses must
explicitly contain `accepted=true`, `stored=false`, `guidanceEligible=false` and
`freshnessVerified=false`; event ID and Binding ID must match.

## Authentication boundary

Only explicit `demo-mobi-local` and `http://127.0.0.1:<port>` are supported. Production
authentication is intentionally not implemented. HTTP redirects and environment
proxy inheritance are disabled. The local Auth Emulator is trusted as part of the
single-PC demo, not an externally reachable credential service. Do not expose it.

`EmulatorProducerAuth.login(email, password)` obtains UID, ID token and refresh
token from the Emulator REST password endpoint. Password is not retained. Tokens
are in memory only, excluded from errors and ordinary logs. A synchronized token
cache renews 60 seconds before the reported expiry using the securetoken endpoint.
This is token maintenance, not role authorization: the backend reads current
server-managed role claims on every request. A refreshed UID must stay identical.
Failed authentication/refresh never falls back to cached credentials or admin access.

Firebase REST reference: https://firebase.google.com/docs/reference/rest/auth
Emulator boundary: https://firebase.google.com/docs/emulator-suite/connect_auth

Actual integration found that the installed Admin SDK Emulator JWT verification
does not enforce `exp`. Backend `verify_user` now independently requires a finite
numeric future expiry. This preserves the existing expired-token 401 policy.
Production signature/revocation/account checks are unchanged. The integration
expiry test edits only an unsigned Emulator JWT's exp, not a production token.

## Immutable event and sequential sending

```python
auth = EmulatorProducerAuth(project_id="demo-mobi-local")
auth.login(email, password)  # obtain password using getpass, not a CLI argument
client = VisionProducerClient("http://127.0.0.1:8011", auth)
client.attach_binding(server_created_binding)
event = VisionEvent.create(server_created_binding, detection_result,
                          frame_index=frame_index, captured_at=actual_capture_time,
                          capture_clock="unknown")
receipt = client.send(event)
client.close()
auth.close()
```

Create once per original frame. `VisionEvent` holds immutable bytes and returns a
decoded copy for inspection. All HTTP attempts send those exact bytes; token
renewal changes only Authorization. `digest` is a wire-byte SHA256 for local
identity, not the server's semantic fingerprint. Request and DetectionResult
schemas plus timestamp/source/bbox consistency are validated locally.

Each camera has a lock spanning token acquisition, HTTP and bounded backoff.
Different cameras can run concurrently. Same-camera new frames cannot overtake
an unresolved event. Increasing source frame indexes may have gaps (sampling or
safe unsent discard); never relabel a failed frame as a new observation. New event
IDs with an old index are rejected locally; the server remains the final authority.
Recent acknowledged event digests (128 per Binding) allow exact receipt retries.
There is no background queue, worker thread or unbounded retained frame payload list.

## Retry and failure policy

| Outcome | Action |
|---|---|
| 202 | Validate original receipt, acknowledge event |
| 401 | At most one forced renewal within attempt budget; same bytes |
| 403 | Stop, disable local Binding; never try another identity |
| 409 | Stop; whitelist conflict/order/age reason, no automatic re-ID |
| 422 / other unexpected HTTP | Stop |
| 503 / network exception | Same-byte bounded retry; delivery can be uncertain |
| Invalid 202 receipt | Stop as uncertain; block subsequent frame |
| Auth service failure | Fail closed; no unauthenticated backend request |

Defaults: 3 total POST attempts, delays 0.1 then 0.2 seconds (exponential, capped
at 1 second), 4-second send budget, 2-second per-request timeout and 4-second
capture-age horizon. These are configurable demo transport limits, not measured
safety thresholds. HTTPX timeouts apply to individual network phases, not a strict
whole-system scheduling deadline. Clock synchronization and camera capture latency
still require measurement. Historical replay may be discarded by this Client's
age horizon; increasing a receipt test horizon never makes replay live-eligible.

Unsent expired events are known discards (`uncertain=false`). After timeout/503 a
server commit may have happened (`uncertain=true`). The exact pending event and
its monotonic retry deadline are retained; a manual send cannot extend that
deadline. A different frame is blocked. Expired uncertain events require explicit
server-admin reconnection/new Binding and epoch to resume. Reattaching the same
Binding cannot clear pending state or an authorization failure. Earlier evidence
is never repackaged under the new Binding.

## Restart and Binding lifecycle

The Client does not create Binding permissions. Obtain Binding JSON from the
authenticated admin workflow. A new Binding must also have a new cameraEpoch.
Attach it after the server confirms it; old Envelopes stay bound to the old epoch.
Server auth/Binding/ledger/time validation is never bypassed locally.

No durable automatic Client outbox is implemented. For Client restart retain the
original Envelope bytes in a protected local file and retry that same event first,
within its age horizon, before sending new frames. Do not store tokens/passwords
with it. Binding must still be valid. Backend restart currently loses memory
Bindings; retries are 403 even when RTDB receipt survives. Re-register the camera
and obtain a new session/Binding/epoch, then create a genuinely new frame/event.
Do not reuse event IDs with changed Binding payloads. This is retry-safe processing,
not an exactly-once delivery guarantee or multi-worker Binding support.

## CLI and integration

Existing Envelope fixture (no retimestamping):

```powershell
& backend/api/.venv/Scripts/python.exe -B scripts/send_vision_v2_fixture.py `
  --backend-url http://127.0.0.1:8011 --binding <server-binding.json> `
  --event <immutable-envelope.json> --email <local-producer-email>
```

Actual Emulator smoke (Auth 9099, RTDB 9000, separately owned Backend 8011):

```powershell
& backend/api/.venv/Scripts/python.exe -B scripts/smoke_vision_producer_client.py `
  --backend-url http://127.0.0.1:8011 --report <external-report.json>
```

Optional `--restart-checkpoint <fresh-external-base>` uses `.ready` and `.continue`
markers exactly like the existing server smoke. Only restart a backend you own,
never the existing 8001 demo. Tokens stay in the smoke process. Test-only receipt
retry horizon is extended for the deliberate backend restart; server time checks
are not changed. Smoke creates/deletes only its own accounts and RTDB records.

`--rtdb-failure-marker` is only for an externally prepared owned-backend fault
harness, not an ordinary backend option. The audit harness reroutes ledger SDK
references to a closed loopback port while the marker exists. It uses real SDK
network requests and verifies no receipt was committed; the existing Emulator is
not stopped. Response loss is separately injected after an actual HTTP 202. Both
must be distinguished from a physical outage and from MockTransport unit tests.

Future Streaming runner integration: obtain server Binding once per connection,
construct a new immutable Event for each original DetectionResult frame, call send
sequentially, and stop/reconnect on uncertain expiry or Binding rejection. Preserve
actual capture time/source and frame index. Do not route v2 receipt acceptance to
passenger guidance. No Streaming code is merged or webcam launched in this step.
