# Session-scoped Safety Event delivery

SafetyEvent records and existing ingestion response schemas remain unchanged.
The admin producer must explicitly bind ingestion to an active Guidance session;
unbound legacy events are stored according to the existing policy and never
broadcast. No global /safety-events/recent feed is exposed to passengers.

## HTTP contract

POST /ai-vision/events or POST /safety-events optionally accepts BOTH query
parameters sessionId and generation. Existing admin authentication is required.
The existing BackendSafetyEventClient accepts paired session_id/session_generation
and an injected standard httpx.Auth; missing/partial binding fails before HTTP.
Its default remains unbound and unauthenticated (no implicit admin authority).
Generation is the active vision_generation returned by the session feed. The
backend verifies ownership (when userId exists), active session and generation
before storage, then rechecks under the session lock before delivery. A reset
between persistence and publication can leave a stored but undelivered event;
producers must not blindly retry. Existing no_event responses stay HTTP200,
stored=false; AI positive ingestion stays HTTP201.

GET /guidance/safety-events?sessionId=... is passenger/admin authenticated.
Ownership is checked through observation_scope, never inferred from event text.
Response: sessionId, ownerUid, generation, cursor (nonnegative sequence), events.
Initial polls return an empty events list plus a baseline cursor. Subsequent
polls provide after and generation. Each event contains sequence, eventId,
message, timestamp, expiresAt (UTC Unix seconds), validForSeconds, synthetic,
and priority=info. Reset rotates generation; closed/boarded sessions reject.
A different generation establishes a server baseline, and an existing Flutter
receiver closes rather than silently adopting a new session generation.

## Policy and lifecycle

The feed is bounded (128 entries/session), process-local and non-durable. It
reuses FreshnessPolicy: max frame age5s, future skew1s, observation TTL3s by
default. A strictly increasing source timestamp watermark rejects reordered
frames; visionEventId deduplicates retransmission. Unknown policies are silent.
The initial supported policy is bus_door_visible / bus_door / info with existing
confidence>=0.55. Only explicit ai_vision_live/ultralytics provenance is accepted
normally. No direction, distance or boarding permission is inferred. Arbitrary
producer message text is not spoken. Other event policies await review.

Synthetic delivery additionally requires APP_ENV=test AND
MOBI_SYNTHETIC_GUIDANCE=true, and uses an explicit synthetic message label.
Flutter rejects synthetic messages by default; test/debug injection is rejected
in release mode. No authentication bypass was added to production code.

The normal V3 page creates its receiver after session creation, pins the current
UID and FirebaseAuthSession request guard (including same-UID login epochs),
and uses the existing AuthenticatedApiClient. Safety GET requests use HTTP
AbortableRequest. Timeout/receiver disposal requests cancellation. A shared
per-origin safety-flight lease is held until the ORIGINAL authenticated HTTP
and response-body future terminates, even if a custom transport ignores abort.
Rebuilding receivers/clients cannot bypass that lease. Such transports leave
safety delivery BLOCKED until completion; no new transport is silently selected.
Each subscription owns its own cancellable channel; it never closes the shared
HTTP client used by unrelated APIs. Token/refresh waits also check cancellation
before transmission and unauthorized callbacks. Auth invalidation closes the feed
and audio. Reset/remount/dispose invalidate pending work. Polling is once/second
with a2s request timeout and no overlapping original safety requests per origin.
Operational retry delays are capped exponential 2/4/8/16/30seconds, with at most
one retry timer. Success resets backoff and establishes a no-replay baseline;
401/403/retired-auth responses close the receiver rather than retry indefinitely.
Reset uses SessionSafetyLifecycle: synchronously invalidate the old receiver,
show RESETTING, await the server reset, validate the current auth/page and
response session, and only then mount a new receiver. Failure never resurrects
the old receiver; the user can explicitly retry. Concurrent resets are ignored. Initial/reconnect history
is consumed without replay. Late/error/malformed responses suppress audio.
Client TTL subtracts round-trip time. Duplicate message meaning is suppressed
within the receiver scope; no replay on enabling voice or completing Hold.
Audio is OFF by default. The existing SpeechPriorityCoordinator handles
low-priority speech and Live Hold preemption; no TTS/Spatial implementation
was changed. Existing Hold identical-text dedup limitations are unchanged.

## Validation boundaries

External local runtime harness uses Fake authenticated principals, mock storage
and a Fake SpeechEngine. It is not imported by the normal app. Runtime fixture
provenance is SYNTHETIC_EVENT_GUIDANCE. Captured real YOLO outputs remain
REAL_MODEL_NO_EVENT. Physical sound, real Firebase auth/storage, production
sensor-to-session binding, multi-worker delivery and model-positive detection
are NOT_VERIFIED. No Firebase/IAM/ADC access is needed for these tests.
