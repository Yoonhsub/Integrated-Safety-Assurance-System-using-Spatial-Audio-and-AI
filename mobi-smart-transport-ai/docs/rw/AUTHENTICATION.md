# Backend authentication and authorization

## Runtime policy

Firebase Authentication ID tokens are required as `Authorization: Bearer <ID token>`.
The existing firebase-admin==6.6.0 verifies signature, issuer, audience, expiry and revocation
with `verify_id_token(check_revoked=True, clock_skew_seconds=0)`. Disabled/deleted accounts are
rejected. Current server-managed account custom claims are fetched for each request; stale
role claims in a token are not authorization evidence. No raw token or SDK failure is returned.

- Missing/invalid/expired/revoked token or disabled/deleted account: 401, WWW-Authenticate: Bearer.
- Valid identity with missing role/mapping, wrong role or foreign resource: 403.
- Firebase configuration, certificate lookup, account lookup or verification service outage: 503, fail closed.
- No USE_MOCK_DATA/FIREBASE_USE_MOCK authentication bypass. Firebase Auth emulator configuration
  is rejected because its unsigned-token mode is inappropriate for this server.
- Only tests explicitly override get_principal. Legacy behavior tests inject admin; independent
  auth_boundary tests exercise real dependencies with the Firebase SDK stubbed.

## Server-managed provisioning (deployment prerequisite)

Trusted administrators must provision existing Firebase accounts with custom claims:
`mobi_role`: passenger, driver or admin; drivers additionally require `mobi_driver_id`.
No registration endpoint can self-assign these claims. RTDB users.role is a profile field,
not an authorization source. A driver UID and fleet driver ID are independent identifiers.
Do not infer their relationship. Verify the real driver account, route and vehicle before
assigning claims and `/drivers/{driverId}` (existing busNo/routeId fields). Do not provision
roles from a client's request body. Admin access spans users and must be tightly restricted.
The actual administrators, onboarding/approval process and production account mappings remain
for the project owner to establish; no real account or role has been registered by this change.

Passenger userId must equal the verified UID. Passengers can read/cancel their own requests;
drivers can list/read/process only requests whose targetDriverId equals their trusted mapping.
Passenger-supplied targetDriverId additionally must match server driver routeId and busNo.
Unassigned requests cannot be claimed by arbitrary drivers. Existing state transition checks remain.
This assignment lookup does not establish physical vehicle identity or permit Live boarding.

## Route inventory

The exact method/path allowlist is `backend/api/app/security.py` (POLICY/PUBLIC).
A test compares it with every registered business HTTP/WebSocket route. New routes default deny.

| Category | Operations | Identity |
|---|---|---|
| Public | root, health, GET bus-info/stops/{stopId}/arrivals, GET bus/arrivals | none |
| Passenger | ride creation, geofence, guidance session/state/reset, beacon decision, agent conversation/TTS/STT including WebSockets | passenger or admin; ownership where session/resource is present |
| Shared ride resource | get/status | owner passenger (cancel only), assigned driver or admin |
| Driver | both canonical and alias list/status APIs | mapped driver or admin |
| Route/map utility | destination-candidates, route-plan GET/POST, route-recommend, live-route-status, nearby-stops, walking-route, navigation live-status, config data-mode | any provisioned role |
| Internal/operator | notifications, safety events, AI Vision ingestion, Firebase status/initialize, guidance event, beacon ingest/latest/reset | admin |
| Demo mutations | mock/geofence, mock/beacons, mock/bus-event | admin and APP_ENV development/test/local |

OpenAPI/docs and any built static passenger web assets remain public; they grant no API permissions.
Authentication is applied before business handlers. CORS preflight is not business authorization.

## Guidance sessions and streams

Passengers first POST /guidance/session with `{}` and use the returned sessionId. Client-chosen
IDs and legacy demo-session are not implicitly created for passengers. Other users' sessions are
403; unknown or lost sessions are 404. Reset preserves ownership. Navigation cache includes UID
and sessionId to avoid cross-user reuse. Session ownership currently lives in this process, so
restart/multiple workers require new sessions or a future durable ownership store; do not load
legacy RTDB snapshots as owned sessions. RTDB session reads are closed to clients.

All three WebSocket routes require a bearer header at handshake. Conversation checks session
ownership before external tools. Streams close at token expiry or after at most 60 seconds;
reconnection rechecks revocation and current role. Revocation during a connection is therefore
not instantaneous. Browser WebSocket cannot set arbitrary headers: a future authenticated,
single-use short-lived ticket flow is needed for browser streams. No token-in-URL bypass is added.

## Internal services

Internal endpoints are fail-closed to ordinary passenger/driver tokens. They currently accept
explicitly provisioned admin operator tokens; this is not completed machine authentication.
Do not embed an admin user's token in mobile apps or persistent collectors. For deployed AI/BLE
collectors prefer platform service-account OIDC with exact audience and service identity allowlist,
or a trusted authenticated gateway that prevents direct-origin bypass. Deployment platform,
audience and identities must be supplied before implementing that policy. Until then automated
collectors and unauthenticated BLE ingest are intentionally blocked. Live boarding remains on hold.

## Configuration and rollout

FIREBASE_PROJECT_ID is mandatory. FIREBASE_SERVICE_ACCOUNT_PATH (relative to project root or
absolute) supplies an Admin credential; when absent Application Default Credentials are used.
The credential must have Firebase Authentication user lookup rights in the correct project.
The separate named mobi-auth app is independent of storage Mock fallback. Never ship credentials
in apps or Git. Keep host time synchronized; HTTPS and deployment network controls are required.

Deploy `infrastructure/firebase/database.rules.json` separately after review: sensitive ride,
driver and guidance reads are API-only. Driver location and FCM writes require the explicit driver
claim mapping; passenger location/FCM use UID and passenger role. RTDB evaluates token claims, not
per-request Admin account lookup: already-issued tokens may retain direct-write permission until
expiry. For immediate direct-write revocation, a separate revocation-aware RTDB rule policy or
backend-only write API is still needed. No rules deployment or emulator security test has been run.

Apps currently have no login. Backend enforcement therefore blocks existing tokenless Live calls
with 401. Next app work: enable an agreed Firebase login provider; add firebase_auth; use actual UID;
attach/refresh ID tokens for HTTP, handle 401 reauthentication / 403 permissions / 503 retry without
safety authorization; use trusted driver provisioning, server-created session IDs and logout cache
cleanup. Never put an admin credential in either app. Login provider and real Firebase project
configuration have not been selected or modified by this implementation.

## Validation scope

Mock SDK tests validate error translation and application authorization, not Google's cryptographic
verification or real IAM/rules deployment. Run real-project staging tests with passenger/driver A/B,
revoked/expired tokens, disabled users, service outages and direct RTDB access before release.
Existing API response schemas are retained. Backend smoke explicitly injects an in-process admin
only with Mock storage; it is not proof that existing apps have authenticated successfully.

References: https://firebase.google.com/docs/auth/admin/verify-id-tokens
and https://firebase.google.com/docs/auth/admin/custom-claims

### Concrete app compatibility changes

- apps/passenger_app/lib/src/pages/home_page.dart uses passenger-demo-001 and ride-driver-001:
  replace these with authenticated UID and server-provisioned assignment data.
- apps/driver_app/lib/src/pages/home_page.dart uses ride-driver-001:
  use the explicit authenticated driver's mapping, never assume UID equals fleet ID.
- Both backend_api_client.dart implementations need bearer token injection and error handling.
- passenger v3_agent_api_client.dart creates sessions with a supplied ID and calls /guidance/event.
  Change session creation to omit sessionId. The generic event endpoint can inject authoritative
  boarding states, so it is now admin-only. Do not give the passenger app admin access; a subsequent
  scoped user-action transition contract needs review before migrating these calls.
- Existing unauthenticated scripts/smoke_v3_guidance.py will receive401 from a protected server.
  It is not silently exempted. Backend guidance regression tests use explicit test-only identity.
