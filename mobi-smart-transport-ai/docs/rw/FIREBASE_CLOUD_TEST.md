# Firebase cloud-test: local FastAPI + isolated real Auth/RTDB

This mode is separate from the `demo-mobi-local` Emulator demo. It does not deploy,
enable Vision v2 in the cloud, grant Producer credentials to Flutter, change TTS,
or change Live Hold. Firebase cloud behavior is unverified until an approved real
test project is supplied and the explicit integration steps succeed.

## Safety boundary

- Use a dedicated, empty Firebase test project with an ID ending in `-cloud-test`.
  Project naming is only a guardrail: confirm that it contains no production data.
- The runtime requires `APP_ENV=staging`, explicit matching project/URL/run values,
  ADC, real storage and separate loopback Web origins. Emulator hosts, local-demo,
  file-based Admin credential configuration, cloud runtime and paid AI environment
  settings are rejected. Never set emulator host variables to the string `false`.
- The first implementation supports the project's **default RTDB instance** only,
  either `PROJECT-default-rtdb.firebaseio.com` or its regional
  `PROJECT-default-rtdb.REGION.firebasedatabase.app` HTTPS URL.
- Start a new process. Do not modify or restart the existing 8001 Backend,
  5173/5174 apps or 9099/9000 Emulators. Example cloud-test ports are
  8011/5183/5184; verify availability before starting any new server.
- Missing/wrong/expired/revoked tokens and current roles retain the existing
  Firebase authentication boundary. Accounts must also belong to the approved
  cloud-test run. Emulator users/tokens are never reused.
- `POST /firebase/initialize` and the legacy seed service reject staging/production.
  Cloud-test `GET /firebase/status` uses a scoped read instead of the write probe.
- Cloud-test dispatch is server-managed and synthetic. It reads an immutable
  `/cloudTestRuns/RUN/assignments` record, validates bus/route/driver profile, and
  rejects a forged client-selected driver. Existing RTDB request CAS/idempotency
  and passenger/driver ownership checks are reused.
- Root RTDB Rules remain deny-by-default. No cloud Rules deploy is performed by
  these tools. The existing rules must be reviewed/applied separately; a dedicated
  client-sensitive read denial is checked by the real smoke.
- The additional cloud-test API allowlist permits only the ride workflow,
  guidance session create/read/reset, scoped status, the blocked legacy-seed
  check, and the still-disabled Vision preview check. It does not enable map,
  LLM, safety-event mutation, notification or Producer administration APIs.
  This first cloud-test is an Auth/RTDB/ride integration environment, not the
  full remote V3 guidance feature set. Public arrival endpoints retain their
  existing policy. Even the test admin cannot access another run's ride data.

## Public configuration and credential preparation

Copy `infrastructure/firebase/cloud-test.example.json` to an external local folder.
Supply the project ID, exact RTDB URL, unique runId and both registered Web apps'
public Firebase configuration. The config accepts only these fields, and no
password, ID token, refresh token or Admin private key.

Backend/bootstrap use ADC. Prefer an explicitly authorized test-only service
account identity, using impersonation where supported, without creating keys.
The bootstrap identity needs test Auth user/claims management and RTDB writes;
the runtime needs Auth lookup/revocation checks and RTDB access. Do not assume
plain `gcloud auth application-default login` works with Firebase Auth: Firebase
documents additional requirements for end-user ADC. Validate the chosen credential
type and scopes on the isolated project. No ADC login or key generation is run by
these scripts. Keep any existing ADC credential configuration outside Git.

Firebase setup is external and separately approved: Email/Password provider,
test Auth/DB IAM, reviewed RTDB Rules, registered passenger/driver Web apps and
appropriate Auth domains/API restrictions. Public Firebase API configuration is
not an Admin secret. Never include service account data or Producer credentials
in Dart defines.

## Offline plan and Web defines

Run from `mobi-smart-transport-ai` with the existing Backend Python environment:

```powershell
python -B scripts/cloud_test.py plan --config C:/private/cloud-test.json --case-id first-smoke-20261019
python -B scripts/cloud_test.py prepare --config C:/private/cloud-test.json --output C:/private/cloud-test-public-build-input
```

`plan`, `prepare`, and an action without `--apply` perform no Firebase network
operation. The plan lists the exact project/run, bootstrap Auth UIDs/DB paths,
deterministic smoke request ID and the session path scope. `prepare` only writes
public `passenger-defines.json` and `driver-defines.json` outside the checkout.
Use these with separate Flutter builds/run outputs; Firebase flags are compile-time.
`MOBI_LOCAL_DEMO=false` uses real Auth; the existing Emulator build remains intact.

## Review the bounded write scope before applying

For a run `trial-20261019-a`, bootstrap creates at most five dedicated Auth UIDs:
`ct-RUN-passenger-a`, `ct-RUN-passenger-b`, `ct-RUN-driver-a`, `ct-RUN-driver-b`,
`ct-RUN-admin`, each using the corresponding `@example.test` address. Server claims
include `mobi_cloud_test_run`; driver auth UIDs map to separate IDs
`ct-RUN-driver-502` and `ct-RUN-driver-105`.

Bootstrap writes only `/drivers/ct-RUN-driver-502`,
`/drivers/ct-RUN-driver-105`, and `/cloudTestRuns/RUN`. No unrelated existing
account/data is adopted or overwritten. The exact matching bootstrap marker can
recover its own partial creation; existing password is not reset. Dispatch `ready`
is published only after roles/profiles exist. Firebase Auth and RTDB are not one
atomic transaction: an error can leave partial test resources, which must be
reported and inspected. No tool automatically deletes users, profiles or requests.
The synthetic assignments use route IDs `MOCK-502` and `MOCK-105` to preserve
the existing app-facing route contract. The records are newly provisioned in
the isolated test project; no Emulator accounts or database data are copied.

Only after a human approves that project and plan:

```powershell
python -B scripts/cloud_test.py bootstrap --config C:/private/cloud-test.json --apply --approved-project-id YOUR-PROJECT-cloud-test --approved-run-id YOUR-RUN
python -B scripts/cloud_test.py backend --config C:/private/cloud-test.json --apply --approved-project-id YOUR-PROJECT-cloud-test --approved-run-id YOUR-RUN
python -B scripts/cloud_test.py smoke --config C:/private/cloud-test.json --case-id first-smoke-20261019 --apply --approved-project-id YOUR-PROJECT-cloud-test --approved-run-id YOUR-RUN
```

Bootstrap and smoke ask for a new, unique cloud-test password with hidden input;
use at least 20 characters. `MOBI_CLOUD_TEST_PASSWORD` is also supported for a
trusted secret-injected environment; do not write it into scripts, command
arguments, Git or logs. A single password is for these disposable isolated test
accounts only. It must not be the existing Emulator password or any real account's.

Smoke writes only the planned synthetic `/rideRequests/ride-i-HASH` and one
server-generated `/v3GuidanceSessions/v3-ID` snapshot. It leaves the request
cancelled and retains records for inspection. Use a new reviewed `--case-id` for
a fresh full run; retries preserve the old request rather than creating duplicates.
It checks real login/refresh, concurrent POST, UID ownership, wrong driver denial,
server dispatch, acceptance/cancellation, same-key conflict/replay, legacy seed
denial, session ownership, Vision 503 and direct RTDB sensitive-read denial.

Reports contain check names and IDs, not credentials or raw provider errors.
Failures are sanitized and return a nonzero exit code. A failed run is not PASS;
inspect configuration/IAM and the bounded test resources, without broad reset.

## Tests and remaining limits

`backend/api/tests/test_cloud_test.py` covers configuration, SDK-stub auth scope,
read-only status, seed prohibition, explicit memory dispatch/CAS races, offline
tools and write approvals. These are **Mock/unit tests**, not cloud verification.
Existing real Emulator regression remains a separate result. No cloud success is
implied by either suite. A target project, IAM and user authorization are required
for actual cloud smoke.

Vision v2 remains Emulator-only (503 here). Guidance session memory is still the
authority; RTDB snapshot persistence is best-effort and does not support restart
recovery or multiple workers. Run one local Backend worker. Camera/Session Binding
persistence, remote deployment, Android real-device verification and operational
rollout remain future tasks. `guidanceEligible=false`, `freshnessVerified=false`
and Live Hold remain unchanged. No demo detection implies boarding permission.

## 2026-10-20: explicitly approved main-project test mode

The earlier dedicated-project instructions above remain the default. The user
has chosen `mobi-smart-transport` instead; this section describes that distinct
mode and supersedes the earlier dedicated-project requirement only for this ID.
No actual cloud connection, database creation, Rules deployment, Auth bootstrap
or cloud write has been performed as part of this local implementation update.

- Set public config `projectId` to `mobi-smart-transport` and
  `mainProjectTest` to the JSON boolean `true`. Other non-test project IDs remain
  forbidden. The generated server environment requires
  `MOBI_CLOUD_TEST_MAIN_PROJECT=mobi-smart-transport` as an additional exact guard.
- Real `--apply` also requires `--allow-main-project-test`, plus the existing
  `--approved-project-id` and `--approved-run-id`. These switches implement a
  guard; they do not substitute for human approval of the concrete plan.
- All cloud-test Admin RTDB reads/writes/transactions in this mode are mapped
  under `/cloudTestRuns/RUN`. The logical manifest becomes
  `/cloudTestRuns/RUN/manifest`; logical application records become
  `/cloudTestRuns/RUN/data/{drivers,rideRequests,v3GuidanceSessions,...}`.
  Existing root drivers, requests, sessions and other runs are not read or written.
  Path traversal, root operations and explicit foreign-run paths are rejected.
  Firebase Admin credentials still have broad IAM authority: this application
  guard is not an IAM sandbox and cannot restrict other programs using that identity.
- Auth itself has no RTDB namespace. In main-project mode only four `ct-RUN-*` users are
  provisioned; existing users, passwords and roles must not be changed or adopted.
  Run IDs must be fresh and reviewed. Matching own partial-run recovery retains
  the existing exact-marker checks. There is no account listing or mass cleanup.
- Create RTDB in locked mode only after reviewing the intended location and
  project. Do not replace existing Rules without checking their current contents;
  direct client access to `/cloudTestRuns` must stay denied, including ancestor
  grants (a child deny cannot override a parent allow). Admin bypasses these Rules.
- Database URL/region must be copied from Console after creation; do not infer a
  provisioned database from the expected URL pattern. Registered public Web app
  config, authorized ADC identity and Email/Password setup are still prerequisites.
- Before cloud writes, show `plan` output with exact URL, run, four main-project Auth UIDs,
  bounded database paths and smoke case; obtain approval for that concrete scope.
  No cloud resource or Rules changes are authorized merely by this local change.
- Existing Emulator services, demo accounts and app builds remain unchanged.
  Vision v2 remains disabled in cloud-test; TTS, BLE, Live Hold and safety flags
  are unchanged. Single-worker/in-memory session limitations still apply.

Example offline plan (after completing public config outside Git):

```powershell
python -B scripts/cloud_test.py plan --config C:/private/main-project-test.json --case-id main-smoke-20261020
```

The main-project URL and full app IDs are now user-confirmed (see the 2026-10-21 section). ADC/IAM, current public API-key validity and approved run scope still require preparation.
Mock tests of this mode are not evidence of real Firebase connectivity.


## 2026-10-21: confirmed identities and no main-project admin

Confirmed by the user, without a cloud query in this implementation task:

- Project: `mobi-smart-transport`
- Database: `https://mobi-smart-transport-default-rtdb.asia-southeast1.firebasedatabase.app/`
- Passenger: `1:882602390759:web:461d3d1331226ae71e1e42`
- Driver: `1:882602390759:web:d1c4863d29510afc1e1e42`

The earlier Driver input `1:882602390759:web` was incomplete; it was not a
different valid app ID. The full value was recovered from the saved public
Console settings and reconfirmed by the user. App ID checks now reject incomplete
IDs, wrong project/sender/auth domain and swapped Passenger/Driver mappings before
preparing a build. These public IDs grant no Admin access. The Firebase API key
is still supplied through external public config; it is never a service key.
The confirmed main database URL (with optional trailing slash) is pinned too.

Main mode provisions ONLY two passengers and two drivers. Plan output lists four
UIDs and `createsGlobalAdmin=false`. Before any SDK initialization, bootstrap
checks the exact four UIDs and role/driver mappings. It refuses an injected admin
or an unexpected account plan. Authentication also rejects a main test UID whose
current claims were elevated to admin, and rejects the old `ct-RUN-admin` identity.
Existing main-project accounts are not adopted or changed.

Four-account cloud smoke can check login/refresh, 401, cross-passenger and wrong-
driver 403, server dispatch, CAS/idempotency, accept/cancel, payload conflict,
session ownership, passenger seed denial, Vision 503 and direct RTDB access denial.
An admin-authenticated seed/status test is explicitly deferred. The existing
legacy-seed route/service admin guard remains covered by offline tests with an
injected test principal. Those tests create no Firebase admin user. If actual
admin-authenticated integration is required, use a separately approved dedicated
staging project; main-mode bootstrap offers no switch to create admin.

Dedicated projects ending in `-cloud-test` retain their old five-account behavior.
Never rename or relabel the main project to bypass this boundary. Firebase claims
and IAM are different: this change removes the test user's global admin claim,
but does not make the bootstrap credential's IAM authority path-scoped.

### External local config and build arguments

Copy the example to a fresh directory outside Git. It now contains the confirmed
main project, URL, full App IDs, `mainProjectTest=true` and a proposed run ID;
public API-key placeholders still prevent accidental execution of the template.
The root `.env.example` is a development Mock example with the current project,
an empty Storage Bucket and no key-file path. Copying it does not enable cloud-test.
Use only the explicit cloud-test launcher in a clean, separate process.

`prepare` emits distinct Passenger/Driver `--dart-define-from-file` inputs with
`MOBI_LOCAL_DEMO=false` and the separate loopback Backend URL. Existing Emulator
defines still use `demo-mobi-local` and `MOBI_LOCAL_DEMO=true`. Do not pass the
Passenger defines to the Driver build. Build-argument tests cover both names and
preserve the current Hosting `/passenger/` and `/driver/` base href paths.

No Storage Bucket has been inferred. Cloud Storage remains outside this task.
Google provider enablement alone does not implement a Google login UI; current
shared AuthSession login uses email/password.

### ADC and IAM preparation (manual, separate approval)

1. Choose a runtime service identity for this test and a separate, short-lived
   bootstrap operator identity. Do not grant Owner/Editor merely to make tests pass.
2. Runtime requires Auth user lookup for current roles/revocation and RTDB data
   access. It does not need Auth account-create or claims-update privileges.
   Bootstrap needs account creation/lookup/current-claims management plus RTDB
   access. Scope the grant duration and project; document the exact identities.
3. Prefer keyless service-account impersonation through ADC when supported by
   installed Google Cloud CLI/google-auth. Firebase CLI login is independent of
   Backend ADC. Creating service-account keys is not part of this workflow.
4. Standard end-user `gcloud auth application-default login` is not sufficient
   evidence of Firebase Auth support: Firebase documents additional OAuth-client
   and explicit-project requirements. Confirm credential type/scopes before use.
5. Review the project's existing IAM and Rules under separate read authorization.
   Admin SDK normally bypasses RTDB Rules. `/cloudTestRuns/RUN` mapping is an
   application guard, not an IAM guarantee for an arbitrary program with ADC.
6. Do not run `backend --apply`, bootstrap or smoke yet: backend startup performs
   a real scoped read, bootstrap reads/writes Auth and RTDB, and smoke logs in,
   refreshes tokens and mutates its planned test records.

References: https://firebase.google.com/docs/admin/setup and
https://firebase.google.com/docs/database/admin/start and
https://firebase.google.com/docs/projects/iam/permissions .

This task does not log into ADC, modify IAM, access cloud resources or deploy Rules.
The actual selected credential's permissions and ability to access cloud Firebase
remain unverified until a separately approved cloud integration run.

### Hosting now and possible future split

Current Hosting stays on site `mobi-smart-transport` with `/passenger/` and
`/driver/`; no Hosting config change is made. A later two-site deployment would
need separate site mappings/public folders, root `/` base href builds (or agreed
paths), matching SPA rewrites, both site origins in Backend CORS, and authorized
Auth domains/Google redirect setup. The Driver site would be
`mobi-smart-transport-6e401`. Common Firebase authDomain need not be renamed just
because the Hosting site differs. Do not deploy the old `.invalid` API compile build.

### Scope approval, retention and known limitations

Before an actual read/write run, approve exact project/URL/run/case, four Auth
UIDs and their passenger/driver claims, two scoped driver records, one manifest,
one deterministic request per smoke case and a generated session snapshot.
The run ID in the example is proposed, not checked for cloud collisions. Existing
bootstrap preflight rejects differing records/accounts; use a new run and never
overwrite unrelated data. Matching own partial recovery is still permitted.
Auth and RTDB are not one atomic transaction; partial resources must be reported.

Retain non-secret evidence and test resources for at most seven days after review,
then use a separately approved exact-UID and exact-run cleanup. No automatic TTL,
cleanup command, global account listing or bulk deletion is implemented. Never
reuse a cleaned run ID. Storage/credentials and operating data are not cleanup targets.

Guidance session snapshots remain best-effort; HTTP 200 alone does not prove RTDB
persistence. Future authorized integration must confirm the exact scoped session
snapshot, and one local worker is required. Restart recovery, persistent Binding,
cloud Vision v2 and cloud Observation/TTS end-to-end remain outside this task.
Live Hold and all safety flags remain unchanged.


## 2026-10-21 Auth 실행기 안전성 보완 (이전 절차를 대체)

이 절의 단계별 실행 절차가 위의 과거 `bootstrap`/`smoke` 일괄 실행 예시보다
우선한다. 과거 시점의 검증 결과는 당시 기록이며 이번 변경의 검증 결과가 아니다.
실제 Firebase Authentication 통합은 아직 실행하지 않았다.

### 계정 및 실행 승인

- 모든 cloud-test 프로젝트에서 승객 2명·기사 2명만 허용한다. admin 및
  vision_producer 생성은 허용하지 않는다. 현재 검토 대상 run은 `auth-20261021-a`다.
- UID, 이메일 및 Claims 전체가 계획과 일치해야 한다. `mobi_cloud_test_run`,
  `mobi_role`, 기사 `mobi_driver_id` 외 Claims도 거부한다.
- 최초 생성 전 후보 UID와 이메일 4쌍을 모두 조회한다. 기존 계정이 있으면
  다른 사용자로 간주해 생성·Claims 변경을 중단한다. 개인 Google 계정을 수정하지 않는다.
- 같은 원본 실행 기록으로 재실행하는 경우, 생성 시각·랜덤 소유 표식·이메일·
  Claims가 모두 일치하고 이미 완료된 계정만 읽기 전용으로 확인한다.
  기존 Claims를 재설정하지 않는다. Claims 설정 전 실패한 계정은 정리 후 새 run을 쓴다.
- 계정 생성과 RTDB 저장은 원자적이지 않다. 실행 기록을 mutation 전에 저장하므로
  응답이 유실되면 intent/불확실 상태가 남는다. 계정 소유 표식이 정확히 일치할 때만
  제한된 실패 복구 정리를 허용한다.

### 명시적인 단계

`plan`, `prepare`는 로컬 작업만 한다. `bootstrap --apply`, `smoke --apply`는
폐기되어 항상 거부된다. 새 단계는 다음과 같다.

1. `preflight`: 승인된 UID/이메일과 초기 RTDB 레코드 3개만 충돌 확인. 원격 쓰기 없음.
2. `auth-bootstrap`: Bootstrap 가장 ADC로 계정 4개 생성·Claims 설정·재조회.
3. `rtdb-bootstrap`: auth-bootstrap 완료 기록을 확인하고 기사 2개와 manifest만 CAS 생성·재조회.
4. `backend-smoke`: Runtime 가장 ADC로 기존 인증 HTTP 시나리오를 실행. 요청 1개,
   세션 1개만 허용하고 저장을 별도 재조회한다.
5. `flutter-smoke`: URL과 수동 확인 절차를 안내하며 자동 PASS를 반환하지 않는다.
   로그인·로그아웃·화면 표시는 실제 브라우저 확인이 필요하다.
6. `cleanup`: 이번 run의 테스트 클라이언트와 Backend 중지 확인 후 정리한다.
   기존 데모 서비스를 중지하는 명령은 포함하지 않는다.

클라우드 실행 예시의 인자는 사용자가 해당 작업을 승인한 뒤에만 전달한다.
이 문서는 실행 승인이 아니다.

```powershell
python scripts/cloud_test.py plan --config <public-config.json> --case-id auth-smoke-a
# planSha256와 정확한 계정/경로/단계별 변경 범위를 검토하고 별도 승인받는다.
python scripts/cloud_test.py auth-bootstrap --config <public-config.json> `
  --case-id auth-smoke-a --journal <저장소-밖-비공개-폴더>/execution.json `
  --apply --approved-project-id mobi-smart-transport `
  --approved-run-id auth-20261021-a --allow-main-project-test `
  --approved-stage auth-bootstrap --approved-plan-sha256 <검토한-해시>
```

모든 원격 단계는 정확한 project/run/stage/planSha256 승인이 필요하다.
`GOOGLE_APPLICATION_CREDENTIALS`에 stage별 가장 ADC 파일을 명시해야 한다.
backend/backend-smoke/flutter-smoke는 `mobi-ct-runtime@PROJECT.iam.gserviceaccount.com`,
나머지는 `mobi-ct-bootstrap@PROJECT.iam.gserviceaccount.com`만 허용한다.
사용자 ADC·서비스 계정 키·다른 가장 대상·인증 override는 SDK 접근 전에 거부한다.
기존 ADC를 변경하거나 IAM을 자동 확대하지 않는다. 실행기 인자는 사람의 승인을
대체하지 않으며, 인자 전달은 승인 절차를 수행한 운영자의 책임이다.

### 비공개 로컬 실행 기록과 정리

- `--journal`은 저장소 밖의 현재 사용자 전용 폴더에 둔다. Windows에서는
  폴더 ACL을 현재 사용자 중심으로 제한한다. Claims/합성 UID/레코드만 저장하며
  비밀번호·토큰·ADC 원문은 저장하지 않는다.
- executionId는 랜덤 128비트 값이며 계정 displayName과 초기 RTDB 레코드 표식에 반영한다.
  journal은 IAM 경계나 서명된 소유권 증명이 아니다. 파일을 공유하거나 임의 편집하지 않는다.
- 단계 전체에 파일 잠금을 적용하고 원자적 교체·fsync로 기록한다. 동시 실행은 거부한다.
  강제 종료 후 잠금이 남으면 프로세스와 부분 리소스를 확인한 뒤 별도 수동 복구한다.
- 정리는 계정 최대 4개, RTDB 레코드 최대 5개(기사 2개, manifest, 요청, 세션)를 허용한다.
  부모 run 전체 또는 RTDB 루트 삭제는 금지한다.
- 계정은 UID/이메일/소유 표식/가능한 생성 시각/Claims 확인 후에만 삭제하고 다시 조회한다.
  이미 존재하던 다른 계정과 소유 표식이 달라진 계정은 삭제하지 않는다.
- RTDB는 저장 당시 확인한 값과 현재 값이 일치할 때만 ETag 조건부 DELETE 후 null을 확인한다.
  SDK 6.6의 transaction(None)은 삭제를 지원하지 않아 실제 정리는 조건부 REST DELETE를 쓴다.
- 삭제 실패는 대상별 오류 유형만 보고한다. 정상 정리 PASS, 일부 실패 PARTIAL,
  전부 실패 FAILED로 구분하고 PARTIAL/FAILED는 CLI도 실패 종료한다.
- 세션 생성 응답을 잃으면 ID를 모를 수 있다. pendingSession은 정리를 미확인으로
  유지하며 부모 삭제나 광범위 조회로 우회하지 않는다. 정확한 경로를 별도로 승인받아 복구한다.
- cleanup을 시작한 run에서는 다시 생성·재생하지 않는다. 같은 cleanup 재시도는 가능하다.
  테스트 종료 즉시 정리하고 남은 리소스는 보고한다. 자동 TTL이나 자동 IAM 회수는 없다.

### 실제 저장과 접근 차단 판정

- Backend HTTP 성공과 Admin SDK를 통한 RTDB 재조회 성공을 구분한다.
- 실제 요청 저장 경로는 `scope.storage_path('/rideRequests/' + requestId)`다.
  HTTP 경로 `/ride-requests/`를 RTDB 경로로 사용하지 않는다.
- 직접 클라이언트 토큰 GET은 이 실제 경로에서 401/403이어야 한다.
  이는 Backend Admin SDK의 승인된 접근과 별도 검사이며 Rules를 수정하지 않는다.
- 안내 세션의 기존 best-effort 저장 정책은 변경하지 않았다. HTTP 200이어도
  해당 scoped snapshot이 전체 일치하지 않으면 backend-smoke는 실패한다.
- 세션은 여전히 단일 프로세스 메모리가 기준이다. Backend 재시작 복구나 다중 worker
  안전성을 주장하지 않는다. 메모리·HTTP 대역 통과는 실제 Firebase 통합 PASS가 아니다.
- 기존 Live Hold, TTS, BLE, Vision 안전 플래그 및 클라우드 Vision 비활성 정책은 유지한다.

### 로컬 Emulator 검사

옵트인 테스트 `test_cloud_test_lifecycle_emulator.py`는 고정 loopback 포트
Auth 9199/RTDB 9100 및 demo-mobi-local 프로젝트만 사용한다. 실제 Admin SDK/HTTP로
계정 생성·Claims·충돌·부분 실패 정리·RTDB CAS·직접 접근 차단을 확인한다.
테스트 전용 어댑터를 사용하며 실제 클라우드 ADC나 Production 검증 우회 설정을
제품 코드에 추가하지 않는다. Flutter 화면이나 클라우드 IAM을 검증하는 테스트는 아니다.


## 2026-10-23 HIGH 보안 리뷰 수정 — 현재 실행 정책

이 절은 위 과거 절차의 자동 Auth 삭제, journal 표식 기반 삭제 및 메인 프로젝트
Auth bootstrap 설명을 대체한다. 과거 실행 결과를 소급 변경하지 않는다.
이번 수정에서 실제 Firebase, IAM, ADC에는 접근하지 않았다.

### configHash와 생성 증거

- configHash/planSha256은 설정·계획 일치 검사다. journal 전체 무결성이나
  생성 소유권을 증명하지 않는다. journal과 같은 권한으로 편집할 수 있는
  서명·표식·expected 값은 독립 증거로 인정하지 않는다.
- 자동 RTDB 정리는 같은 Lifecycle 프로세스가 absent→created 트랜잭션 성공과
  값 재조회를 확인해 메모리에 보유한 정확한 경로/값/실행 ID의 생성 증거만 사용한다.
  journal에 이 증거를 저장하거나 journal에서 복원하지 않는다.
- 재시작 또는 별도 cleanup CLI에서는 이 증거가 없으므로 journal에 기록된
  RTDB 항목을 자동 삭제하지 않는다. MANUAL_REQUIRED로 보고한다.
- 메모리 증거가 있는 항목도 값 비교와 ETag 조건부 DELETE 및 삭제 후 null 검증을
  거친다. ETag는 생성 소유권 증거가 아니며 삭제 시점의 경쟁 조건 방어다.
- 부모 run 경로는 증거 유무와 관계없이 자동 삭제하지 않는다.
- 이 정책은 journal 파일 변조를 방어한다. 실행 프로세스 메모리/코드 자체를
  조작할 수 있는 공격자를 방어하는 보안 경계라고 주장하지 않는다.

### Auth: 원자성 미보장에 대한 fail-closed

- 메인 mobi-smart-transport의 auth-bootstrap은 계정 조회·생성·Claims 변경 전에
  차단한다. 허용 플래그로 우회하는 기능은 추가하지 않았다.
- Firebase Auth의 별도 get/update/delete 호출은 원자적인 소유권 검사와 변경을
  제공하지 않는다. 파일 잠금과 추가 재조회만으로 외부 관리자 UID 교체를 막을 수 없다.
- 별도 테스트 프로젝트에서는 신규 create_user 응답의 생성 시각이 확인되고
  직후 재조회한 UID/이메일/표식/생성 시각/빈 Claims가 일치하는 경우만 Claims를 설정한다.
  기존 계정에 Claims를 설정하지 않는다. 재조회 전 교체는 탐지하고 중단한다.
- 최종 검사와 set_custom_user_claims 사이의 교체는 여전히 변경 후에야 탐지될 수 있다.
  이 잔여 위험을 재현하는 테스트를 유지한다. 메인 프로젝트는 이 경로를 실행하지 않는다.
- Auth 자동 삭제는 모든 프로젝트에서 비활성화했다. cleanup은 Auth 조회/삭제를
  호출하지 않고 정확한 UID를 MANUAL_REQUIRED로 보고한다. Bootstrap에 삭제 권한을
  요구하지 않는다. 수동 Auth 정리는 별도 사용자 승인·신원·배타적 운영 계획이 필요하다.
- 생성 응답 유실, 생성 시각 누락, Claims 설정 실패 시 계정은 남을 수 있다.
  이를 성공적인 정리로 표시하거나 자동 삭제로 복구하지 않는다.

### 세션 응답 유실 및 정리

현재 Backend에는 이 실행기가 신뢰할 수 있는 요청 ID→생성 세션 ID 복구 API가 없다.
기존 HTTP 응답의 정확한 세션 ID와 snapshot을 실행 기록에 남기되, readback만으로
독립적인 생성 증거가 확보됐다고 판단하지 않는다. 세션 자동 삭제는 허용하지 않는다.
응답 유실은 pendingSession/FAILED로 남기며, ID 추측·부모 조회/삭제로 우회하지 않는다.
알려진 정확한 ID도 별도 수동 확인과 정리 승인이 필요하다.

### 신원별 책임과 최소 permission 설계 (IAM 변경 미실행)

| 신원 | 승인된 작업 | 필요한 permission 후보 | 요구하지 않는 권한 |
|---|---|---|---|
| Runtime | 현재 사용자 확인, 승인된 Backend 데이터 처리 | firebaseauth.users.get, firebasedatabase.instances.get; 데이터 변경 승인 단계에만 firebasedatabase.instances.update | Auth create/update/delete |
| Bootstrap | 별도 테스트 프로젝트의 신규 계정 생성·Claims 설정 | firebaseauth.users.get/create/update; RTDB bootstrap 승인 단계에만 instances.get/update | firebaseauth.users.delete |
| Cleanup | 별도 승인된 정확한 리소스 정리 | RTDB get/update; 수동 Auth 정리 승인 시에만 users.get/delete | Auth create/update |

위 표의 RTDB permission은 firebasedatabase 접두사, Auth permission은 firebaseauth
접두사를 사용한다. 실제 API 호출에 필요한 최종 IAM 권한은 향후 별도 승인된
메타데이터 조사에서 다시 확인한다. 서비스 사용/할당량 권한도 필요한 경우만 추가한다.
RTDB IAM은 이 run의 경로만으로 제한된 권한이라고 주장하지 않는다.

cleanup ADC는 mobi-ct-cleanup@PROJECT.iam.gserviceaccount.com만 허용하도록 분리했다.
Cleanup 계정/권한이 없으면 중단하며 Bootstrap으로 대체하지 않는다.
기존 Runtime 가장·ReadOnly 바인딩은 2026-10-23 09:00 KST에 만료된 것으로 취급한다.
자동 갱신하지 않는다. 이번 코드 수정은 계정·역할 생성이나 클라우드 실행 승인이 아니다.

정리 결과는 모든 대상 확인 PASS, 수동 확인 포함 PARTIAL, 모든 대상 실패 FAILED로
구분한다. CLI는 PARTIAL/FAILED에서 실패 종료한다. 메인 프로젝트 Auth 통합은 현재
BLOCKED이며, 실제 실행 전에 독립 재검토와 별도 승인된 후속 설계가 필요하다.


## 2026-10-23 MEDIUM 보완 — 프로젝트 등록과 run 경로 통일

이 절은 과거 전용 프로젝트의 루트 경로 허용 설명과 패턴 기반 Web 설정 검증 설명을
대체한다. 과거 결과는 당시 기록이며 현재 클라우드 실행 승인이 아니다.

### 확인된 등록 설정만 사용

- backend/api/app/cloud_test.py의 CONFIRMED_TEST_PROJECTS는 현재 비어 있다.
  실제 신규 Firebase 프로젝트의 등록 설정을 아직 확인하지 않았기 때문이다.
- 프로젝트별 Console 원본 공개 설정을 사람이 확인하고 코드 리뷰한 뒤 이 등록 목록에
  고정한다. 실행 config, journal, 환경변수, CLI flag로 등록 목록을 채우는 기능은 없다.
  운영자가 임의로 verified=true를 넣거나 해시를 계산해도 소속 확인 증거가 되지 않는다.
- 등록 항목 형식은 projectId, databaseUrl, passenger, driver 네 필드다. 각 Web 항목은
  MOBI_FIREBASE_API_KEY, MOBI_FIREBASE_APP_ID, MOBI_FIREBASE_MESSAGING_SENDER_ID,
  MOBI_FIREBASE_PROJECT_ID, MOBI_FIREBASE_AUTH_DOMAIN 전체가 Console 값과 일치해야 한다.
  API key도 등록 값과 대조한다. 등록 목록은 공개값이며 Admin 키나 ADC를 넣지 않는다.
- 미등록 프로젝트는 CLI plan/prepare/apply와 Backend 설정 검증에서 네트워크·ADC 접근 전에
  거부된다. 현재 별도 프로젝트의 실제 클라우드 실행 판정은 BLOCKED다.
- 메인 App ID 또는 senderId 882602390759를 테스트 프로젝트에 복사하면 거부한다.
  두 앱의 역할별 App ID 교체, 키 변경, senderId 불일치, 다른 등록 DB URL도 거부한다.
- 사용자 메시지의 1:882602390759:web는 불완전한 Driver App ID다. 이전에 확인된 전체
  Driver 값 1:882602390759:web:d1c4863d29510afc1e1e42는 그대로 유지하며 잘라 쓰지 않는다.
- 등록 목록과의 일치 검사는 오프라인 정책 검사다. Firebase 클라우드 메타데이터로 소속을
  자동 검증했다고 주장하지 않는다. 실제 Console 원본·프로젝트 번호·앱별 설정 확인은 미완료다.
- 등록 값 또는 API key 변경도 실행 계획 해시에 반영된다. 설정 해시는 소속 증명이 아니며,
  계획 변경 후 기존 승인 해시를 재사용하지 못하도록 하는 기능이다.
- 단위·Emulator 테스트는 테스트 함수의 monkeypatch로 합성 등록을 주입한다.
  이 테스트 값은 실제 Firebase 등록 값이 아니며 제품 등록 목록에 포함하지 않는다.

### 모든 Cloud-test의 동일한 RTDB 매핑

mainProjectTest 값과 관계없이 다음 매핑을 사용한다.

| 논리 경로 | 물리 경로 |
|---|---|
| /drivers/<id> | /cloudTestRuns/<runId>/data/drivers/<id> |
| /rideRequests/<id> | /cloudTestRuns/<runId>/data/rideRequests/<id> |
| /v3GuidanceSessions/<id> | /cloudTestRuns/<runId>/data/v3GuidanceSessions/<id> |
| 내부 manifest 별칭 /cloudTestRuns/<runId> | /cloudTestRuns/<runId>/manifest |

- run 부모와 manifest leaf는 다르다. 저장소에 전달하는 내부 manifest 별칭도 실제로는
  /manifest 한 항목을 가리키며 부모 전체 삭제를 허용하지 않는다.
- 이미 매핑된 물리 경로, 타 run 경로, 루트, 점·빈 구성요소·역슬래시 등을 논리 경로로
  넘기면 거부한다. 다중 경로 update의 상대 키 검사는 전용 프로젝트에도 동일하게 적용한다.
- Backend get/set/update/push/delete/transaction은 같은 FirebaseClient 매핑을 사용한다.
  기사 목록은 해당 run의 data/rideRequests만 읽는다. 세션 readback도 동일하게 매핑된다.
- 직접 RTDB 접근 차단 smoke와 실행 계획·정리 physicalPath도 이 매핑을 사용한다.
- 과거 journal physicalPath가 이전 루트 레이아웃이면 자동 정리하지 않고 오류로 거부한다.
  기존 데이터는 자동 이관·삭제하지 않는다. 필요한 경우 정확한 leaf를 별도 승인받아 수동 확인한다.
- Cloud-test가 아닌 기존 서비스의 저장 정책은 변경하지 않는다.

### 유지되는 HIGH 방어와 후속 승인

메인 Auth 생성·Claims 변경 차단, 전 프로젝트 Auth 자동 삭제 금지, 생성 증거 없는 RTDB
자동 삭제 금지, 재시작 후 증거 복원 금지, journal 변조 방어와 ETag 조건부 삭제를 유지한다.
Auth Claims TOCTOU는 원자적으로 해결되지 않았으며 별도 프로젝트의 잔여 위험도 그대로다.
세션 생성 HTTP 성공과 RTDB 저장 확인은 구분하며 ID 유실은 수동 확인 대상으로 남긴다.

실제 프로젝트/RTDB/Web 앱 준비와 Console 공개 설정 대조, 등록 목록 변경에 대한 코드 리뷰,
전용 Runtime/Bootstrap/Cleanup IAM·ADC, 정확한 계정·run·경로별 실행 승인, 별도 수동 정리
승인이 필요하다. 이번 수정에서 클라우드 조회·계정 생성·IAM·ADC 변경은 수행하지 않았다.
TTS, Vision, Live Hold와 안전 플래그를 변경하지 않았다.


현재 infrastructure/firebase/cloud-test.example.json은 main이 아닌 신규 테스트 프로젝트의
Console 확인값을 채우는 placeholder 예제로 변경했다. 그대로는 실행되지 않으며, 값을 채워도
코드 리뷰된 등록 목록이 없으면 거부된다. 기존 main 설정을 기본값으로 재사용하지 않는다.


## 2026-10-23 신규 테스트 프로젝트 Console 등록값 반영

이 절은 앞 절의 CONFIRMED_TEST_PROJECTS가 비어 있다는 현재 상태 설명을 갱신한다.
사용자가 제공한 두 firebaseConfig 원본을 기준으로 mobi-auth-cloud-test 한 항목을
오프라인 검토해 등록했다. Firebase Console/API에 접속해 메타데이터 소속을 다시 조회한
결과는 아니며, 프로젝트 리소스나 Auth 설정의 실제 상태를 검증했다고 주장하지 않는다.

| 항목 | 사용자 제공값 |
|---|---|
| Project ID | mobi-auth-cloud-test |
| Sender ID | 189730626159 |
| Passenger App ID | 1:189730626159:web:407d25db8c026703170b9a |
| Driver App ID | 1:189730626159:web:b486ec4c18abf663170b9a |
| Auth Domain | mobi-auth-cloud-test.firebaseapp.com |
| RTDB | https://mobi-auth-cloud-test-default-rtdb.asia-southeast1.firebasedatabase.app |

두 앱의 Firebase 웹 API key는 제공된 원본의 동일한 공개값을 정확히 사용한다.
이는 Admin/ADC 비밀키가 아니다. 서비스 계정·토큰·비밀번호는 추가하지 않았다.
제공된 storageBucket 및 measurementId는 현재 Auth/RTDB 실행 계약에 필요하지 않으므로
등록/Flutter defines에 추가하지 않았고 Storage·Analytics를 활성화하지 않았다.
메인 프로젝트 등록과 보호 정책, 앱별 ID 혼입 차단, Auth 자동 삭제 금지와 경로 격리는 유지한다.

### ADC 없이 수행하는 오프라인 점검

```powershell
python scripts/cloud_test.py preflight --config <외부-public-config.json> --case-id offline-registration
python scripts/cloud_test.py prepare --config <외부-public-config.json> --output <새-외부-defines-폴더>
```

위 명령은 --apply를 지정하지 않는다. preflight 출력은 검토용 실행 계획이며
networkPerformed=false다. 실제 UID/이메일 충돌 조회, IAM 상태, Auth 제공업체,
로그인 또는 RTDB 연결을 검증하는 원격 preflight가 아니다.
--apply는 별도 승인과 단계별 ADC가 있어야 하며, ADC가 없으면 SDK 접근 전에 거부된다.

생성한 passenger-defines.json/driver-defines.json을 각 앱 디렉터리에서
flutter build web --dart-define-from-file=<해당-앱-defines.json>으로 전달할 수 있다.
MOBI_LOCAL_DEMO=false와 별도 로컬 Backend 주소가 들어간다. 이번 작업에서 Flutter
빌드/서버 시작/실행 중 앱 교체는 수행하지 않았다. main 전용 Hosting 준비 도구는 사용하지 않는다.

신규 원본값의 역할별 ID, API key 해시, main 프로젝트 혼입·교차·변조·미등록 거부,
ADC/HTTP 호출을 금지한 오프라인 preflight, 앱별 defines와 동일한 run 경로를 회귀 테스트한다.
기존 합성 테스트 등록값과 사용자 제공 등록값을 구분하며 실제 Firebase 통합 결과로 혼동하지 않는다.

실제 Auth 통합 전에는 Email/Password 제공업체·기본 차단 Rules 확인, 테스트 프로젝트 전용
Runtime/Bootstrap/(향후 Cleanup) 신원·IAM·가장 ADC, 정확한 계정/Claims/run/물리 경로와
변경 건수 승인 및 별도 수동 정리 계획이 필요하다. 이번에는 IAM/ADC에 접근하지 않았다.
Bootstrap에 Auth 삭제 권한을 추가하지 않으며, Claims TOCTOU 잔여 위험도 유지한다.


## 인증 UI 전용 실행 경계 추가 (2026-10-23)

실제 Flutter 로그인 UI 검증 전에 발견한 두 경계를 보완했다. 기존 승객 Home/V3 화면은
초기화 시 안내 세션 생성 요청을 할 수 있으므로 인증만 승인된 실행에서 열지 않는다.
공유 AuthGate는 Passenger/Driver 앱의 mobi_role 및 기사 ID를 확인한 뒤 업무 화면을 연다.
이 UI 검사는 Backend의 현재 역할·UID·소유권 검증을 대체하지 않는다.

### 격리된 인증 전용 빌드

scripts/cloud_test.py prepare의 공개 defines를 새 외부 폴더로 복사하고 아래 두 값을 추가한다.
기존 실행 중인 앱의 설정 및 build/web을 덮어쓰지 않는다.

```json
{
  "MOBI_AUTH_ONLY": "true",
  "MOBI_AUTH_TEST_RUN_ID": "auth-20261023-919e07bd"
}
```

각 앱 디렉터리에서 해당 역할의 defines로 빌드한다.

```powershell
flutter build web --release --no-pub --dart-define-from-file=<외부-auth-only-defines.json> --output=<새-외부-web-폴더>
```

MOBI_LOCAL_DEMO=false, Project ID=mobi-auth-cloud-test가 필수다. 공유 초기화 코드가
오프라인 검토된 test 프로젝트의 API key, authDomain, senderId와 역할별 App ID를
Firebase 초기화 전에 대조한다. 신규 등록을 허용하려면 해당 목록을 별도로 검토해야 한다.
이는 실시간 클라우드 메타데이터 조회가 아니다. 알려진 메인 프로젝트 및 앱 ID 혼입은 거부한다.

인증 전용 화면은 승인 run의 승객 a/b와 기사 a/b UID 및 Claims만 허용한다. 기사 ID는
각각 해당 run의 driver-502/driver-105여야 한다. 인증 결과 화면에는 UID·이메일·역할·run·
기사 ID와 로그아웃만 제공하며 비밀번호나 토큰은 표시하지 않는다. 직접 URL 이동도 같은
인증 전용 화면으로 제한한다. Home/V3/카메라/오디오/Backend 클라이언트는 생성하지 않는다.
따라서 RTDB 읽기·쓰기나 Backend IAM/ADC 권한은 이 UI 검증에 필요하지 않다.

로그아웃·계정 전환·화면 해제는 generation을 무효화한다. 오래된 Claims 조회와 로그아웃
결과가 새 계정 화면을 변경하지 않는다. SDK 로그아웃 성공 후 스트림 이벤트가 없더라도
현재 계정이 없음을 확인한 경우 로그인 화면으로 돌아간다. 실패하면 접근 차단을 유지한다.
일반 빌드에서는 인증 전용 플래그를 사용하지 않으며 기존 업무 흐름과 안전 정책을 유지한다.

### 검증 범위와 남은 실제 브라우저 검사

공유 AuthGate와 실제 Passenger/Driver 앱 Widget 트리의 테스트는 통제된 Fake AuthSession을
사용한다. 역할 불일치, run/UID/기사 ID 혼입, 오래된 비동기 결과, 로그아웃 실패 및 복원,
직접 경로 이동을 검사한다. 앱 Widget 테스트는 HTTP 요청이나 Backend 토큰 사용을 시도하면
실패하도록 구성한다. 이는 Firebase 실제 브라우저 로그인 성공을 증명하지 않는다.

실제 UI에서는 각 계정 로그인, UID/Claims, 새로고침 후 복원, 역할 교차 차단, 로그아웃,
Console 오류와 Network의 업무 API 요청 부재를 별도로 확인해야 한다. 비밀번호는 승인된
DPAPI 보관본만 사용하고 토큰·ADC 원문은 출력하지 않는다. 브라우저 제어 런타임이
kernel assets 경로 오류로 초기화되지 않은 항목은 NOT_VERIFIED로 남긴다.
Firebase 사용자·Claims·RTDB·IAM·ADC와 메인 프로젝트에는 이 수정 단계에서 접근하지 않았다.
Auth 자동 삭제 금지, Live Hold 및 TTS/Vision 안전 정책은 유지한다.


## 2026-10-25 실제 인증 통합 및 AuthGate 수정 빌드 재검증

이 절은 앞 절의 당시 미검증 기록을 보존하면서 후속 검증 결과를 추가한다.
대상은 별도 프로젝트 `mobi-auth-cloud-test`, 승인 run은 `auth-20261023-919e07bd`다.
메인 프로젝트를 테스트 대상으로 사용하지 않았다.

### 확인된 결과 (PASS)

- 기존 승객 2명·기사 2명의 실제 Email/Password 로그인, ID Token 발급·갱신과 현재 Claims 확인.
- 로컬 FastAPI의 실제 HTTP 인증·인가 18건. 401/403 거부를 확인했고,
  Auth 조회 장애의 503은 실제 클라우드 장애가 아닌 로컬 오류 주입으로 검증했다.
- Passenger·Driver Chrome 인증 E2E: UID·역할·run·기사 ID, 양방향 역할 교차 차단,
  새로고침 인증 복원과 로그아웃.
- AuthGate 로그아웃 경합의 Widget 재현: 수정 전 FAIL, 수정 후 PASS.
  로그아웃 대상 UID를 Claims 조회 generation과 분리하고, 같은 UID 이벤트가
  로그아웃 진행·실패 상태를 해제하지 못하도록 했다. 실패 시 재시도 경로를 유지한다.
  현재 SDK 계정과 다른 오래된 스트림 이벤트와 이전 Claims/로그아웃 결과도 폐기한다.
- 수정 후 Flutter 자동 회귀: Passenger 128 + Driver 3 + mobile_auth 35 = 166 PASS.
  신규 경계 테스트 11개를 포함한다. 세 영역 analyze, 두 인증 전용 Web release 빌드,
  현재 소스 스냅샷 Architecture와 diff 검사도 통과했다.
- 수정 빌드의 실제 시크릿 Chrome 재검증: 승객 A 로그인·로그아웃·동일 계정 재로그인,
  A 로그아웃 후 B 로그인, 기사 A 로그인·기사 502 확인·동일 계정 재로그인,
  새로고침 복원 및 최종 로그아웃 후 로그인 화면 유지를 확인했다.
  관찰한 로그아웃 이후 이전 계정 화면은 다시 나타나지 않았고 캡처된 Console warn/error는 0개였다.

### 검증 한계 (NOT_VERIFIED 유지)

- 실제 Firebase SDK에서 동일 UID 이벤트와 지연 signOut의 정확한 경합 순서를 강제 재현하지 않았다.
  통제된 Widget 이벤트 순서의 PASS와 실제 Chrome의 정상 로그아웃·재로그인 PASS는 별개다.
- 실제 Chrome Network 개별 요청 전체 목록·메서드·상태 코드 검사는 미완료다.
  RTDB·업무 API 요청 부재에 대한 Network 상세 확인도 NOT_VERIFIED다.
  인증 전용 UI 문구나 Fake HTTP 차단 테스트를 이 Network 검사의 대체 증거로 사용하지 않는다.
- 로컬 정적 서버 GET 200/304 및 제공 JS의 빌드 파일 SHA256 일치와 Chrome의 해당 JS URL 로드는
  확인했다. 브라우저 메모리의 JS 파일을 별도 추출해 바이트 비교한 검사는 아니다.
- 실제 Flutter E2E는 인증 전용 모드에서만 수행했다. 일반 업무 화면은 기존 경로와 역할 검사를
  유지하며, `MOBI_AUTH_ONLY` 기본값은 false다. 일반 모드에도 명시적 역할 검사가 적용된다.
- Web release는 JavaScript 빌드로 통과했다. Passenger의 flutter_tts Wasm dry-run 호환성 및
  두 앱의 CupertinoIcons font 경고는 남아 있으며 Wasm 동작을 검증했다고 주장하지 않는다.

재검증은 기존 5183/5184 서버를 유지하고 수정 빌드를 임시 5185/5186에서 제공한 뒤
새 서버만 종료했다. 입력 자동화의 빈 비밀번호 1회 제출은 입력 오류로 구분했고,
정상 길이 입력 후 재로그인을 확인했다. 비밀번호·ID Token·Refresh Token·ADC 원문과 HAR는
저장소에 기록하지 않는다. 테스트 계정은 유지하고 브라우저 테스트 세션은 로그아웃했다.
Auth 자동 삭제 금지와 메인 프로젝트 Auth 보호, Live Hold·TTS·Vision 안전 정책은 유지한다.
RTDB 업무 통합과 임시 IAM 권한·데이터 생성·정리는 별도의 범위 승인 이후 진행한다.
