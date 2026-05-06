# MOBI 정합성 패치 노트

패치 기준: `mobi_final_github_ready_required_package.zip`  
패치 목적: 4개 AI 에이전트 병렬 개발 시 기준 문서, API 계약, shared schema, FastAPI skeleton, Firebase rules, PR 규칙 간 정합성 확보

## 핵심 패치 요약

1. `docs/agent_required_reading/01_요구사항명세서.md`가 잘못된 필독 문서 목록 내용으로 들어가 있던 문제를 수정했다.
   - 공식 SRS는 `docs/01_요구사항명세서.md` 단일 기준으로 고정했다.
   - legacy SRS 파일은 기준 문서가 아님을 명시했다.

2. API 성공 응답 wrapper 충돌을 제거했다.
   - `success/data/message/timestamp` wrapper를 공식 계약에서 제거했다.
   - FastAPI/Pydantic/shared JSON Schema의 raw response 구조를 공식화했다.

3. 버스 도착 정보 계약을 통일했다.
   - 공식 endpoint: `GET /bus-info/stops/{stopId}/arrivals`
   - app-facing 응답에서 `stopName`, `source`를 제거했다.
   - 정류장명은 `/busStops` 또는 앱 로컬 캐시, 원천 메타데이터는 내부 로그/metadata로 분리하는 원칙을 명시했다.

4. 선행작업 의존성 해석을 정리했다.
   - 선행 미구현 시 전체 중단이 아니라, 선행 산출물이 필요한 하위 작업만 보류하도록 명확화했다.
   - 이미 `packages/shared_contracts`에 존재하는 계약은 공식 초안 계약으로 인정했다.

5. PR 템플릿과 CODEOWNERS를 강화했다.
   - `docs/read/PULL_REQUEST_RULES.md`의 필수 항목을 PR 템플릿에 반영했다.
   - docs/scripts/API/DATA/shared_contracts 등 공통 영역을 4인 전체 리뷰 대상으로 추가했다.

6. FastAPI skeleton과 shared schema를 보강했다.
   - `NotificationRequest.type` 추가: `SAFETY_ALERT`, `RIDE_REQUEST`, `SYSTEM`
   - `GeofenceCheckRequest.timestamp` 추가
   - `GeofenceCheckResponse.eventId` nullable 허용
   - `GET /drivers/{driverId}/ride-requests` skeleton 추가
   - notification 및 driver ride request shared schema 추가

7. Firebase rules를 최소 보안 기준으로 강화했다. [v3에서 superseded]
   - 초기 패치에서는 `/users/$uid`와 `/drivers/$driverId` 아래 일부 `fcmToken` write를 허용했으나, v3 이후 공식 FCM 저장 위치는 `/fcmTokens/{ownerType}/{ownerId}`로 단일화했다.
   - 초기 패치에서는 `/rideRequests` 일부 직접 write를 허용했으나, v3 이후 상태 변경은 FastAPI/Admin SDK 경로로 통일했다.

8. 검증 스크립트를 강화했다.
   - 단순 파일 존재 확인뿐 아니라 SRS 단일 기준, API wrapper 제거, bus endpoint, shared schema 필드, PR 템플릿 필수 항목, ownership 기준을 검사한다.

## 변경 파일 성격

- `.docx` 파일은 수정하지 않았다.
- Markdown, Python, JSON, Dart skeleton, GitHub 설정 파일만 패치했다.

---

## 2026-05-06 추가 정합성 패치

첨부된 재검토 지적 중 실제 패치 ZIP에 대해 정당한 항목을 반영했다.

### 반영한 항목

1. `docs/read/AGENT_REQUIRED_READING.md`와 `docs/rw/README.md`의 AI 에이전트 필독 목록에 `docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md`를 최우선 문서로 추가했다.
2. `docs/01_요구사항명세서.md`의 버스 도착 API 경로를 `/bus-info/stops/{stopId}/arrivals`로 통일하고, `/bus/locations?routeId=`는 4월 MVP 활성 API가 아닌 future 후보로 강등했다.
3. `busArrivals`의 `stopName`/`source`는 app-facing 응답에서 제외하고, 필요 시 내부 캐시/로그 메타데이터로만 다루도록 SRS에 명시했다.
4. `docs/rw/DATA_SCHEMA.md`의 `geofences` 구조를 `infrastructure/firebase/realtime_database.schema.json`과 동일한 배열 기반 구조로 통일했다.
5. `NotificationRequest`는 `targetUserId`와 `targetDriverId` 중 정확히 하나만 허용하도록 backend Pydantic validator와 shared JSON Schema의 `oneOf`를 정렬했다.
6. `GeofenceCheckRequest`는 기존 공식 계약인 `userId`, `stopId`, `lat`, `lng`를 유지하고 `timestamp`만 optional로 유지한다. `latitude/longitude`로 바꾸지 않는다.
7. `packages/mobile_sensors`의 BLE/방향 센서 Dart 모델을 `docs/rw/API_CONTRACTS.md`의 필드명과 직렬화 값에 맞춰 정렬했다.
   - `level` → `signalLevel`
   - `BeaconSignalLevel.veryClose` → JSON `VERY_CLOSE`
   - `DirectionReading.accuracy`는 double이 아니라 `DirectionAccuracy` enum
   - `timestamp` → `updatedAt`
8. `apps/driver_app/pubspec.yaml`에서 기사 앱에 불필요한 `mobi_mobile_sensors`, `flutter_tts`, `speech_to_text` 의존성을 제거했다.
9. `packages/shared_contracts/events/event_types.json`에 `direction_accuracy` enum을 추가했다.
10. `module_ownership.json`에서 공통 아키텍처 소유 경로와 protected 경로의 모호성을 줄이고, 검증 스크립트에 소유권 invariant를 추가했다.
11. `CONFLICT-0000` 계열 예시를 `CONFLICT-YYYYMMDD-HHMM-담당자명-번호` 형식으로 통일했다.
12. `docs/read/CONTRIBUTING.md`의 문서 우선순위를 공통 프롬프트 §2.1 기준으로 정렬했다.
13. `scripts/validate_architecture.py`에 다음 정합성 검사를 추가했다.
   - 공통 프롬프트 필독 목록 포함 여부
   - SRS/API 버스 경로 일치 여부
   - notification one-target 계약 여부
   - geofence RTDB/DATA_SCHEMA 구조 일치 여부
   - mobile_sensors 필드명/직렬화 일치 여부
   - driver_app 불필요 의존성 제거 여부
   - enum 값 일관성
   - conflict ID 형식 일관성
   - module ownership/protected invariant

### 반박 또는 부분 반박한 항목

- Geofence `lat/lng`이 `latitude/longitude`로 바뀌었다는 지적은 현재 패치 ZIP 기준으로는 이미 발생하지 않는다. 다만 같은 오류가 재발하지 않도록 `validate_architecture.py`에 `latitude/longitude` 금지 검사를 추가했다.
- Notification이 `userId` 단일 필드로 회귀했다는 지적도 현재 패치 ZIP 기준으로는 이미 발생하지 않는다. 다만 `targetUserId`/`targetDriverId` 중 “최소 하나”가 아니라 “정확히 하나”가 더 정합적이므로 해당 방향으로 강화했다.
- CongestionLevel/RideRequestStatus는 런타임 import 구조를 무리하게 바꾸면 현 스캐폴딩 테스트가 깨질 수 있으므로, 이번 패치에서는 공통 JSON enum 소스와 검증 스크립트 기반 일관성 검사로 처리했다.


## v3 consistency patch

- 공통 루트 문서와 팀원별 필독/보고 문서를 `module_ownership.json`과 `CODEOWNERS`의 공통 보호 범위에 추가했다.
- 선행작업 미완료 시 처리 원칙을 “섹션 전체 중단”이 아니라 “선행 산출물이 필요한 하위 작업만 보류”로 팀원별 필독 문서까지 통일했다.
- NotificationRequest의 targetUserId/targetDriverId가 빈 문자열이면 Pydantic에서도 거부하도록 JSON Schema와 맞췄다.
- BusArrival의 arrivalMinutes/remainingStops에 `ge=0` 제약을 추가했다.
- RideRequest 생성/상태변경 요청용 machine-readable JSON Schema를 추가했다.
- FCM 토큰 저장소를 `/fcmTokens/{ownerType}/{ownerId}`로 단일화하고 users/drivers 프로필의 중복 fcmToken 필드를 제거했다.
- userType enum을 `visually_impaired | elderly | general | unknown`으로 통일했다.
- rideRequests RTDB 직접 쓰기를 막고 FastAPI/Admin SDK 경로를 공식 상태 변경 경로로 명시했다.
- PUBLIC_DATA_BASE_URL 기본값과 docs/rw/SETUP.md의 FastAPI 실행 명령을 현재 코드 구조에 맞췄다.


## v4 consistency patch

- 문서 우선순위를 역할/범위 기준, API 계약 기준, Firebase RTDB 기준으로 분리했다.
- `docs/02_4월_개인별_구현범위_수정안.md`와 agent_required_reading 복사본의 낡은 백엔드 파일 구조를 현재 FastAPI 구조로 수정했다.
- `congestion` 예시를 shared schema enum과 같은 `NORMAL` 대문자 값으로 정렬했다.
- 센서 예시 필드명을 `headingDegrees`, `updatedAt`, `estimatedDistanceMeters`, `signalLevel`, `lastDetectedAt`로 통일했다.
- SRS의 `alerts/{alertId}`, `beaconSignals/{deviceId}`를 4월 공식 RTDB 경로에서 제외하고 `/systemLogs` 또는 future/debug 항목으로 강등했다.
- `GeofenceCheckRequest.timestamp`는 필드 생략만 허용하고 명시적 `null`은 거부하도록 Pydantic validator를 추가했다.
- RideRequest create JSON Schema의 문자열 필드에 공백 문자열 방지 `pattern: \S`를 추가했다.
- `docs/rw/SETUP.md`의 검증 스크립트 정상 출력 예시를 실제 `Architecture validation: PASS`와 일치시켰다.


## v5 consistency patch

- FastAPI path parameter 이름을 docs/rw/API_CONTRACTS.md와 같은 camelCase(`stopId`, `requestId`, `driverId`)로 통일했다.
- `RideRequestCreate`/`RideRequestRecord` Pydantic 모델에 공백 문자열 거부 pattern을 추가해 shared JSON Schema와 런타임 검증을 맞췄다.
- `NotificationRequest` JSON Schema의 `oneOf`를 강화해 `targetUserId`와 `targetDriverId` 중 정확히 하나만 존재하고, 반대쪽은 없거나 `null`이어야 한다는 Pydantic 의미와 맞췄다.
- `docs/rw/DATA_SCHEMA.md`의 `drivers`, `busStops` 예시를 `realtime_database.schema.json`의 공식 필드와 일치시켰다.
- 오래된 경로 예시(`backend/api/main.py`, `backend/api/app/routes/health.py`, `services/public_data/mock/bus_arrivals.json`)를 현재 구조 기준으로 수정했다.
- `docs/02_4월_개인별_구현범위_수정안.md`와 agent_required_reading 복사본의 Flutter 구조 예시를 실제 `lib/src/...` 구조로 맞췄다.
- `docs/read/CONTRIBUTING.md`의 단순 문서 우선순위를 계약 영역별 우선순위로 확장했다.
- driver app TODO 주석에서 서버 `/notifications/send` API와 FCM 클라이언트 수신 핸들러 역할을 분리했다.


## v6 consistency patch

- Removed generated/ignored files from the package: `__pycache__/`, `*.pyc`, `.pytest_cache/`.
- Updated `docs/read/FINAL_FILE_LIST.txt` and `validate_architecture.py` to reject generated cache files.
- Replaced stale `docs/02` bus-arrival array examples with `NormalizedBusArrivalsResponse` (`stopId` + `arrivals[]`).
- Unified `/health` examples as `{"status": "ok", "service": "mobi-backend-api"}`.
- Replaced stale `CONFLICT-XXXX` examples with `CONFLICT-YYYYMMDD-HHMM-담당자명-번호`.
- Clarified that general document order is for role/scope decisions, while API/DB/security contracts follow contract-specific precedence.
- Renamed `docs/read/AGENT_REQUIRED_READING.md` table semantics from priority to reading order.
- Strengthened notification OpenAPI/Pydantic hints with non-blank target patterns and JSON schema `oneOf` metadata.
- Changed backend/public-data `updatedAt` and ride-request timestamps to `datetime` types where they represent date-time contract fields.
- Clarified `docs/rw/DATA_SCHEMA.md` users.role as `passenger | driver | admin`.

## v7 consistency patch

- Removed remaining stale `signalStrengthLevel` reference and standardized it to `signalLevel`.
- Clarified `lowFloor` as an app-facing boolean contract; unknown raw values are normalized to `false` and may be retained only in internal metadata/logs.
- Standardized remaining congestion fallback wording from lowercase `unknown` to enum value `UNKNOWN`.
- Aligned RTDB bus arrival numeric type labels with shared API/Pydantic contracts: `arrivalMinutes` is `integer`, `remainingStops` is `integer | null`.
- Updated backend test command documentation to use `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1` and `-p no:cacheprovider` for reproducible pytest runs in plugin-heavy environments.
- Added validation checks for stale sensor aliases, lowFloor boolean policy, congestion enum casing, RTDB integer labels, and reproducible pytest command notes.

## v8 consistency patch

- Service layer timestamp values now pass `datetime` objects into Pydantic models instead of `.isoformat()` strings, avoiding `model_copy(update=...)` validation bypass.
- Added `docs/rw/선행작업의존성 정리.md` and `docs/read/architecture_validation_result.txt` to common ownership/protected paths and CODEOWNERS.
- Kept `passenger_app` → `mobi_mobile_sensors` dependency as future integration scaffolding, but documented that April work may use placeholder/mock sensor UI.
- Updated SRS examples: `routeId` now uses `route502`, and geofence response includes optional `eventId`.
- Documented FCM token registration responsibility and `driverId == Firebase Auth UID` policy.
- Added dotenv loading in public data client.
- Aligned required-reading order between the common prompt and `docs/read/AGENT_REQUIRED_READING.md`; docx files are explicitly marked as reference/submission documents.
- Extended `validate_architecture.py` with v8 invariants for the above items.

## v9 consistency patch

- Clarified that `packages/shared_contracts/api/bus_arrivals.response.schema.json` exposes the app-facing `BusArrivalsResponse` contract; `NormalizedBusArrivalsResponse` is only the internal public_data Pydantic model name.
- Updated `docs/02` and the agent-required-reading copy to use `routeId: route502` in the bus-arrival example.
- Reworded the common prompt so `bus_arrivals.response.schema.json` is the official busArrivals contract and `mock_bus_arrivals.json` is a validation/sample fixture, not the source of truth.
- Cleaned up document structure: `docs/rw/SETUP.md` now uses `## 17. 검증 및 테스트 실행`, and `docs/read/CONTRIBUTING.md` no longer has a duplicated trailing `## 2.1.1` section.
- Replaced the empty `flutter:` block in `packages/mobile_sensors/pubspec.yaml` with `flutter: {}`.
- Added v9 invariants to `validate_architecture.py` for the above cleanup items.

## section 7 carryover correction

- Corrected a validation-script carryover mismatch from the API timestamp contract: `GeofenceCheckRequest.timestamp` is optional by omission but explicit `null` is rejected, so the architecture validator now expects `timestamp: datetime = None`.
- Reapplied the README `.docx` policy wording so `.docx` files remain useful reference/submission documents but are not treated as official contract sources.
- Clarified `docs/rw/MODULE_OWNERSHIP.md` so markdown/schema files are official contract/scope sources and `.docx` files are preserved as reference/submission documents.
- Added architecture validation invariants for the section 7 carryover/doc policy corrections.



## section 8 role/ownership consistency patch

- 역할/범위/섹션 진행 우선순위에 `docs/rw/선행작업의존성 정리.md`를 3순위로 명시했다.
- `docs/rw/공통 진행사항.md`와 `docs/rw/선행작업의존성 정리.md`는 공통 보호 파일이지만 자기 기록 공간/자기 선행 섹션 상태에 한해 제한적 최신화가 가능하다고 정리했다.
- 팀원별 에이전트 필독사항의 수정 가능 문서 목록에 `docs/rw/선행작업의존성 정리.md`의 제한적 최신화 권한을 추가했다.
- 안준환 센서 출력 설명을 실제 Flutter UI 수정이 아니라 `packages/mobile_sensors` 내부 예제 또는 로그 출력으로 명확히 했다.

## section 10 core documentation consistency patch

- Revalidated section 9 findings and accepted all 3 as legitimate documentation consistency issues.
- Updated `docs/rw/SETUP.md` backend pytest expected output from `1 passed` to `5 passed`.
- Added Windows PowerShell pytest command example to `docs/rw/SETUP.md` while retaining the Unix/macOS/Linux command.
- Replaced obsolete `docs/read/CONTRIBUTING.md` wording that described branch, PR, and commit rules as temporary fallbacks before dedicated rule documents existed.
- Updated `docs/read/PACKAGE_MANIFEST.txt` and `docs/read/architecture_validation_result.txt` validation metadata to reflect the current 5-test backend suite.

## section 12 Flutter app README clarity patch

- Revalidated section 11 findings: no mandatory Flutter contract conflict was found.
- Accepted the optional README clarity improvement because app-specific README files should not read like a shared template in a GitHub-ready parallel-development scaffold.
- Rewrote `apps/passenger_app/README.md` around passenger-only purpose, April scope, API integration targets, and mobile_sensors dependency policy.
- Rewrote `apps/driver_app/README.md` around driver-only purpose, ride request/FCM scope, API integration targets, and explicit passenger-only dependency boundaries.
- Added validation checks so passenger and driver README files remain app-specific and do not imply cross-app ownership.


## section 14 backend/public-data contract patch

- Revalidated section 13 findings and accepted all 5 backend/public-data consistency issues as legitimate.
- Made `services/public_data` normalized Pydantic models strict with `ConfigDict(extra="forbid")` so normalized output rejects unexpected fields.
- Removed the default `UNKNOWN` value from `NormalizedBusArrival.congestion`; callers must now provide the required shared-contract field explicitly, while `UNKNOWN` remains an allowed enum value.
- Fixed `docs/02` and the agent-required-reading copy to use `BusArrivalsService.get_arrivals(stop_id)` instead of the obsolete `get_bus_arrivals(stop_id)` function name.
- Replaced remaining "최종 응답 wrapper" wording with "최종 응답 객체" so docs do not imply a success/data response wrapper.
- Cleaned up the SRS geofence request/response example so the `eventId` explanation is outside the JSON code block.
- Added `services/public_data/README.md` guidance that standardized bus-arrival output follows `packages/shared_contracts/api/bus_arrivals.response.schema.json` and must not expose non-contract fields such as `stopName` or `source`.

## section 16 sensors/future-modules scope patch

- Revalidated section 15 findings and accepted all 4 mobile-sensors/future-module scope clarity issues as legitimate documentation consistency patches.
- Strengthened `future_modules/spatial_audio/README.md` so actual HRTF/3D rendering is explicitly not implemented in April; the directory is preserved only as a future placeholder/contract frame.
- Strengthened `ai_vision/README.md` so April work excludes actual model training/inference code and Flutter/backend real-time integration.
- Aligned `docs/01_요구사항명세서.md` FR-020/FR-021 sensor output wording with the 안준환/윤현섭 ownership boundary: sensor package examples/logs are allowed, actual app UI reflection belongs to the Flutter app owner.
- Documented `future_head_tracking_status` in `future_modules/head_tracking/README.md` as a reserved future-only enum that must not be emitted by April app/backend code.
- Added section 16 validation invariants to `scripts/validate_architecture.py`.

## section 18 operations/packaging validation patch

- Revalidated section 17 findings and accepted all 4 GitHub operations/packaging consistency issues as legitimate.
- Strengthened `scripts/validate_architecture.py` manifest validation so `docs/read/FINAL_FILE_LIST.txt` is checked bidirectionally: listed files must exist, and every packaged source file must be listed.
- Expanded generated/ignored file scanning to cover `.DS_Store`, `.env`, archive files, logs, `node_modules/`, `.dart_tool/`, `build/`, `.firebase/`, and `.gcloud/` while preserving `.env.example` as an allowed template.
- Aligned `.github/pull_request_template.md` with `docs/read/PULL_REQUEST_RULES.md` by adding explicit 담당 범위 확인, 충돌 이슈, 문서 최신화, and 병합 전 주의사항 sections.
- Added CODEOWNERS alignment checks so key owner paths and common/protected paths remain synchronized with `module_ownership.json`.


## section 20 final consistency patch

- Revalidated section 19 final candidates and accepted both as legitimate final consistency patches.
- Strengthened `/users/{uid}/currentLocation` Firebase validation so it now matches the strict `drivers/{driverId}/currentLocation` schema/rules policy: exact child count, numeric latitude/longitude, coordinate bounds, and string `updatedAt`.
- Aligned top-level AI Vision scope wording across `docs/rw/ARCHITECTURE.md`, `docs/rw/SETUP.md`, `docs/rw/ENVIRONMENT_VARIABLES.md`, `docs/01`, `docs/02`, and the agent-required-reading copy: April excludes actual model training/inference code and Flutter/backend real-time integration; April includes planning/research artifacts only.
- Added final section 20 validation invariants to `scripts/validate_architecture.py`.
