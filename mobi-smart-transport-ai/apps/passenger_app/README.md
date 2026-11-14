# MOBI Passenger App

윤현섭 담당 Flutter 사용자 앱 영역입니다.

## Web demo 실행 방법

> 현재 인증 연동 기준: 이 문서의 아래쪽에 남은 Firebase 데모 초기화 안내는 이전 무인증 데모 절차다. 새 Firebase 프로젝트로 이전 중인 현재 실행에는 적용하지 않는다. 보호 API는 로그인 후 ID token으로 호출하며, Firebase 설정이 없으면 앱은 설정 안내 화면에서 멈춘다.

새 Firebase 프로젝트에서 Email/Password 로그인을 활성화하고 Passenger Web 앱과 Driver Web 앱을 각각 등록한다. 사전 등록 계정만 허용하며 역할 선택이나 계정 생성 UI는 제공하지 않는다. 각 앱을 실행할 때 Console의 공개 Web 설정값을 다음 Dart define으로 전달한다.

```powershell
flutter run -d chrome `
  --dart-define=MOBI_API_BASE_URL=http://127.0.0.1:8000 `
  --dart-define=MOBI_FIREBASE_API_KEY=<web-api-key> `
  --dart-define=MOBI_FIREBASE_APP_ID=<this-web-app-id> `
  --dart-define=MOBI_FIREBASE_MESSAGING_SENDER_ID=<sender-id> `
  --dart-define=MOBI_FIREBASE_PROJECT_ID=<new-project-id> `
  --dart-define=MOBI_FIREBASE_AUTH_DOMAIN=<new-project-id>.firebaseapp.com
```

Passenger와 Driver는 같은 project ID를 쓰되 각각 자기 Web app의 `APP_ID` 값을 사용한다. 로그인 계정에는 서버 측 `mobi_role` claim이 사전 등록되어야 하며, 기사에는 별도의 실제 `mobi_driver_id` mapping도 필요하다. UID와 기사 ID는 같다고 가정하지 않는다. Web API key는 공개 클라이언트 설정이고, Admin service account나 관리자 토큰은 앱에 넣지 않는다.

ID token은 보호 HTTP 요청에 Bearer 헤더로 전송하며, 401이면 한 번 강제 갱신 후 재시도한다. 재시도 후에도 401이면 로그아웃된다. 403은 권한 거부, 503은 인증 서비스 장애다. 브라우저 WebSocket은 현재 인증 헤더를 설정할 수 없어 보호 스트리밍을 사용할 수 없고, 토큰을 URL로 보내는 우회는 하지 않는다. `/guidance/event`, `/firebase/initialize`, BLE ingest 및 mock mutation은 운영자 전용이므로 passenger/driver 앱에서 관리자 권한으로 호출하지 않는다.

실제 통합에는 백엔드의 `FIREBASE_PROJECT_ID`도 새 프로젝트 ID와 일치해야 하며, 그 프로젝트의 Admin SDK credential을 서버 환경에 따로 설정해야 한다. GCP VM 부재는 Firebase 프로젝트 생성과 Web 로그인 개발을 막지 않지만 배포 백엔드가 없으면 보호 API를 end-to-end로 확인할 수 없다.

iPhone 빌드가 병목이므로 우선 Flutter Web 으로 데모를 확인한다. 데모 데이터 쓰기는
Flutter 클라이언트가 아니라 FastAPI 백엔드의 Firebase Admin SDK 가 수행한다.

### 1. 백엔드 실행

```bash
cd backend/api
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

### 2. 상태 확인

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/firebase/status
```

### 3. Flutter Web 실행

```bash
cd apps/passenger_app
flutter pub get
flutter run -d chrome \
  --web-hostname localhost \
  --web-port 5173 \
  --dart-define=MOBI_API_BASE_URL=http://127.0.0.1:8000 \
  --dart-define=MOBI_FIREBASE_API_KEY=<web-api-key> \
  --dart-define=MOBI_FIREBASE_APP_ID=<this-web-app-id> \
  --dart-define=MOBI_FIREBASE_MESSAGING_SENDER_ID=<sender-id> \
  --dart-define=MOBI_FIREBASE_PROJECT_ID=<new-project-id> \
  --dart-define=MOBI_FIREBASE_AUTH_DOMAIN=<new-project-id>.firebaseapp.com
```

### 참고 / 주의

- Firebase Console에서 Email/Password provider를 사용 설정하고, 관리자 사전 등록 계정으로만 로그인한다.
- Passenger와 Driver Web 앱은 별도 등록 후 각각의 공개 Web 앱 설정을 사용한다. Admin service account나 관리자 토큰을 Flutter 앱에 넣지 않는다.
- 백엔드 보호 API는 새 Firebase 프로젝트에 대한 서버 측 Firebase Admin credential과 `FIREBASE_PROJECT_ID` 설정 전까지 사용할 수 없다.
- GCP VM이 없더라도 Firebase 인증 개발은 가능하지만, 배포 백엔드가 없으면 보호 API의 end-to-end 검증은 불가능하다.
- 운영자 전용 Firebase 초기화 버튼은 passenger app에서 제거됐다. WebSocket 인증은 미구현 상태이며 token-in-query 우회는 하지 않는다.


## 목적

`passenger_app`은 시각장애인/노약자/일반 승객이 버스 정류장과 탑승 요청 기능을 이용하는 사용자 앱 스캐폴딩입니다.

## 4월 구현 범위

- 사용자 앱 기본 화면과 라우팅 골격
- 접근성 Semantics 라벨
- 목적지 입력을 위한 STT/TTS 또는 음성 안내 UI 구조
- 지오펜싱 안전 상태, 버스 도착 정보, 탑승 요청 결과 렌더링
- 백엔드 API client skeleton 정리

## 사용자 앱 API 연동 대상

- `POST /geofence/check`
- `GET /bus-info/stops/{stopId}/arrivals`
- `POST /ride-requests`
- `GET /ride-requests/{requestId}`

현재 `backend_api_client.dart`는 shared API 계약 기준으로 실제 HTTP 요청을 시도한다. `POST /ride-requests` live mode payload는 화면 상태의 passenger/user id, 선택된 stop id, 선택된 route id, bus number, 선택적 target driver id를 조합해 생성하며, 클라이언트 내부 고정 demo JSON을 전송하지 않는다.

## 경계

- 백엔드 로직은 `backend/api`에서 구현한다.
- 공공데이터 API 직접 호출은 하지 않고 백엔드 또는 표준 응답을 통해 받는다.
- BLE/RSSI 로직은 `packages/mobile_sensors`에서 구현한다.
- 기사 앱 UI와 기사 전용 탑승 요청 처리 화면은 `apps/driver_app`에서 다룬다.

## mobile_sensors 의존성 정책

`passenger_app`은 향후 BLE/RSSI/방향 센서 기능의 실제 소비자이므로 `mobi_mobile_sensors` path dependency를 유지한다. 단, 4월 범위에서는 BLE/RSSI 실연동 UI가 강한 선행 의존성이 아니며, 윤현섭 에이전트는 placeholder/mock 기반 UI shell을 독립 구현할 수 있다. 실제 센서 연동 확정은 안준환 `packages/mobile_sensors` 산출물 검토 후 진행한다.

## V3 음성 기반 버스 탑승 보조 화면

V3 화면은 홈 화면의 `V3 버스 탑승 보조 열기` 버튼 또는 `/v3-guidance` route로 접근한다.

주요 연결 endpoint는 다음과 같다.

```txt
GET  /health
POST /guidance/session
GET  /guidance/state?sessionId=demo-session
POST /guidance/reset
POST /agent/converse
POST /agent/tts
GET  /bus/route-recommend?destination=사창사거리
GET  /bus/arrivals?stopId=mock-stop-001&routeNo=502
POST /mock/geofence
POST /mock/beacons
POST /mock/bus-event
GET  /beacon/decision
```

API base URL은 Dart define으로 지정한다.

```bash
flutter run --dart-define MOBI_API_BASE_URL=http://127.0.0.1:8000
```

Android emulator에서 로컬 백엔드에 붙일 때는 host loopback 대신 `10.0.2.2`를 사용한다.

```bash
flutter run --dart-define MOBI_API_BASE_URL=http://10.0.2.2:8000
```

Gemini API key가 없어도 V3 화면은 백엔드 rule fallback endpoint를 호출한다. 안전 판단, 지오펜싱 경고, 잘못된 버스 접근 경고는 Flutter가 직접 추측하지 않고 백엔드 rule engine 응답의 `cue`와 `state`를 따른다.

헤드트래킹 debug 표시는 optional이다. 센서가 없어도 앱이 죽지 않도록 기본값은 `optional · 센서 미연결`이며, 현재 V3 화면에서는 yaw/pitch/roll mock 표시만 지원한다. 이 값은 탑승 가능 판단을 대체하지 않는다.

V3 백엔드와 앱의 계약은 `docs/rw/V3_API_CONTRACTS.md`를 기준으로 맞춘다. 전체 시연 순서는 `docs/rw/V3_DEMO_SCRIPT.md`와 `scripts/smoke_v3_guidance.py`를 따른다.

최초 실행에서는 사용자가 에이전트 이름을 지정한다. 저장한 이름은 이후 호출어로
사용된다. 일반 대화는 Gemini Flash, 위치 기반 경로 계산은 Gemini Pro와 Google Maps
grounding, 음성 응답은 `Sulafat` voice를 우선 사용한다.

경로 계산 중에는 화면에 `생각 중...` 오버레이를 표시한다. 결과 화면은 Google Maps
위치 증빙, 실제 청주시 공공 API 정류소 증빙, 별도 도착정보 출처 카드를 구분해서
표시한다. 도착정보가 mock이면 `시연 데이터 · 실제 공공 API 아님`으로 표시한다.


### 탑승 요청 생성 재시도

실제 API 요청에는 Idempotency-Key를 보낸다. 현재 화면에서 첫 클릭 시 무작위 키를 만들고,
기존 shared_preferences에 UID별 미확인 요청 본문/키만 보관한다(토큰/비밀번호 없음).
응답으로 requestId가 확인되기 전에는 같은 키를 재사용한다. 실패 후 다른 노선을 선택하면
미확인 요청 안내를 표시하며 원래 선택으로 재시도해야 한다. 성공 확인 후에는 다음 명시적
클릭을 새 행동으로 취급해 새 키를 만든다. 취소된 요청의 같은 키 응답은 취소 상태 그대로다.
브라우저 저장소 삭제/시크릿 세션/다른 기기/동시 탭까지 같은 사용자 행동을 식별하지는 못한다.
공용 PC에서는 저장된 UID/요청 정보가 남을 수 있다. 자동 만료로 새 키를 발급하지 않는다.
서버409 충돌에서 자동으로 새 키로 재시도하지 않는다. 무키 외부 클라이언트는 이전 동작이다.

## Android 휴대폰 로컬 카메라 시험

카메라/TFLite 추론은 로컬 상태에만 표시합니다. 실행과 모델 준비, 권한/플랫폼 제한은 [ANDROID_LOCAL_VISION.md](../../docs/rw/ANDROID_LOCAL_VISION.md)를 참조하세요. 별도 `lib/local_vision_main.dart` 진입점은 Firebase 및 보호 API가 없는 명시적 오프라인 시험용입니다. 실제 휴대폰 성능과 발열 검증은 별도로 필요합니다.

## AI Vision 관찰 한국어 음성
서버 관찰의 선택적 한국어 TTS와 우선순위·중복·만료 정책은 [VISION_OBSERVATION_TTS.md](../../docs/rw/VISION_OBSERVATION_TTS.md)를 참조하세요. 2026-10-19 PC Chrome에서 한국어 청취, 위험 안내 선점, 관찰 만료 후 TTS ON 상태의 자동 발화 복구를 확인했습니다. 실제 로드 JS와 제공 빌드의 SHA256도 일치했습니다. Android 실기기와 실제 도로 안전성은 미검증이며, 과거 Uncaught Error의 근본 원인은 미확정입니다. Vision 단독 승차 허용은 불가하고 Live Hold를 유지합니다.

## 탑승 요청 업무 UI 로컬 검증 (2026-10-26)

일반 HomePage의 기존 버스 선택과 HTTP API를 재사용한다. RideRequestPanel은
UID별 마지막 요청 ID만 로컬에 저장하고, 재진입 시 서버 GET으로 현재 상태를
복구한다. 로그아웃/계정 변경 시 화면을 비우고 이전 비동기 응답을 무시한다.
취소 PATCH의 409는 최신 상태 GET으로 확인한다. 중복 클릭은 진행 중 차단하며,
응답 유실 후 생성 재시도에는 기존 Idempotency-Key를 재사용한다.
상태 업데이트는 '상태 조회' 버튼으로 확인하며 자동 폴링은 추가하지 않았다.

`flutter test test/ride_business_flow_test.dart`는 실제 승객 요청 Widget과
기사 HomePage/API Client를 Mock HTTP 계약 서버에 연결하는 OFFLINE_UI_E2E다.
로그인 세션은 Fake이며 실제 Firebase 로그인/RTDB E2E 또는 실제 Chrome
검증을 의미하지 않는다. 승인되지 않은 API 경로/메서드 호출은 테스트가 거부한다.
일반 HomePage의 기존 V3 음성 세션 초기화는 그대로이므로 실제 클라우드 UI
검증에는 별도 승인·격리 환경이 필요하다. 인증 전용 모드는 계속 기본 OFF다.

## 전체 HomePage 오프라인 격리 (2026-10-26)

일반 `HomePage(...)`는 기존처럼 initState에서 GET /health, 버스 도착 정보 GET,
POST /guidance/session을 시작한다. `dataMode=mock`는 V3 통신 차단 설정이 아니다.
일반 생성자와 기존 음성·V3·안전 동작은 유지한다.

저장소 밖 Chrome 테스트 진입점 또는 Widget 테스트만 `HomePage.testHarness(...)`를
사용한다. 명시적으로 주입한 AuthSession·BackendApiClient로 실제 HomePage를 마운트하며
V3 Client·STT·오디오 자원을 생성하지 않고 V3/음성 버튼과 접근성 상태를 비활성화한다.
세션 성공 응답을 위조하거나 예외를 삼켜서 격리하지 않는다.

이 생성자는 loopback HTTP API만 허용하고 실제 FirebaseAuthSession 주입을 거부한다.
release에서는 추가로 MOBI_HOME_TEST_HARNESS=true와 Web loopback origin을 요구한다.
일반 앱 라우팅은 이 생성자를 호출하지 않으며 define만으로 테스트 인증이 켜지지 않는다.
Mock 인증 구현은 제품 코드에 추가하지 않았다.

`flutter test test/home_page_isolation_test.dart`는 초기 GET 허용 목록, 요청 DTO,
비활성 버튼·Semantics, 외부 의존성 거부, 재진입과 V3 Client 계약을 검증한다.
전체 HomePage Chrome localhost Mock 23개 시나리오와 기존 Panel/Driver 22개 회귀를
별도로 통과했다. 이 결과는 실제 Firebase·V3·Guidance·음성 검증을 의미하지 않는다.

## 실제 Auth + 업무 API 검증 준비 (방식 A)

별도 target `lib/cloud_ride_verification_main.dart`와 Driver의 같은 이름 target은
실제 FirebaseAuthSession·AuthGate·Bearer 업무 API를 유지한다. 일반 main.dart나
일반 HomePage 생성자는 이 구성을 읽지 않으며 자동 V3 동작을 유지한다.
기존 Fake 전용 HomePage.testHarness의 FirebaseAuthSession 거부도 유지한다.

전용 target은 MOBI_CLOUD_RIDE_VERIFICATION=true, Web loopback origin,
검토된 고정 Data run, 실제 프로젝트별 Web 등록을 모두 요구한다.
CloudRidePlan과 Backend에 과거 Data run `rtdb-20261026-b742c9e1`의
고정 계약을 보존하되, 부분 사용 후 2026-10-27 중앙 퇴역 처리했다. 현재 실행 가능한
클라우드 Data run은 없다. Auth run은 `auth-20261023-919e07bd`, caseId는 `ride-e2e-01`이다.
정확한 공개 계약은 `shared/contracts/fixtures/cloud_ride_ui_target.json`에서
확인한다. 등록은 실제 실행 승인이 아니다. 일반 진입점은 이 계획을 읽지 않으며,
전용 define·Web loopback origin·검토된 Firebase 앱 설정이 모두 필요하다.
환경변수로 임의 run이나 이전 사용 run을 활성화할 수 없다. 실제 로그인·IAM·
RTDB 접근·개별 정리는 별도 승인 대상이다. 실행 전 네 경로 전체의 현재 충돌
검사에 성공해야 하며, 클라우드에 기존 값이 없다는 사실은 오프라인에서 확인할 수 없다.

HomePage.cloudVerification은 V3/STT/오디오를 생성하지 않는다. 업무 호출은
기존 BackendApiClient(useMockData=false)와 실제 ID Token을 사용한다.
공개 버스 GET `/bus-info/stops/mock-stop-001/arrivals`만 메모리 Fixture로
처리하고, 승인된 ct-{dataRun}-stop-502 / MOCK-502 / 502로 매핑한다.
`/busArrivals/{stopId}`는 HTTP API가 아닌 Backend의 RTDB 캐시 경로이며
이 구성에서는 버스 GET을 Backend로 보내지 않으므로 캐시 조회도 발생하지 않는다.
다른 stop·외부 host·query·V3·FCM·Guidance 경로는 전송 전에 거부한다.

보호 API마다 GET /health의 cloudTestProjectId·cloudTestRunId를 검사하고,
실제 Firebase app 등록·현재 UID·역할·Auth run·기사 ID를 대조한다.
허용된 요청 키·DTO·단일 요청 ID·상태 변경만 통과한다. Backend의 UID/Claims/
소유권/CAS 검사는 그대로 유지한다. 클라이언트 가드를 서버 권한의 대체로 보지 않는다.
CloudRideIntentStore는 Data run별 복구 슬롯과 검토된 고정 요청 키를 사용한다.

오프라인 Fixture `shared/contracts/fixtures/cloud_ride_ui_offline.json`은 실제
클라우드 등록이 아니다. Dart의 debug 테스트와 Python monkeypatch 안에서만
동일 계약을 재현하며, cloud Backend의 등록 목록에 추가하지 않았다.
`flutter test test/cloud_ride_verification_test.dart`는 실제 FirebaseAuthSession의
플랫폼만 Fake로 대체한다. 이 검증은 실제 Firebase 로그인·JWT 서명 검증이 아니다.
새 run의 기록·IAM·ADC·Firebase 접근 및 운영 배포는 이 변경으로 승인되지 않는다.

전용 Web 산출물은 반드시 `scripts/build_cloud_ride_web.ps1 -App passenger
-Output <저장소 밖 경로>`로 만든다(기사는 `-App driver`). 기본 HTML은 사용자 제스처에 반응하는 기존
음성/위치/Spatial JS helper를 포함하므로, 이 스크립트가 **검증 산출물에서만**
mobi_*.js 태그를 제거한다. 제품 HTML·Spatial Audio 코드는 수정하지 않는다.
직접 flutter build target만 지정한 산출물을 검증 서버에 제공하지 않는다.

### 인증 세대와 퇴역 Data run 보호

FirebaseAuthSession은 동일 FirebaseAuth delegate의 로그인 세대를 공유한다.
로그아웃·로그인 시도 및 SDK 인증 이벤트에서 이전 세대를 무효화하고,
진행 중인 로그아웃보다 새 로그인이 먼저 완료되지 않도록 인증 변경을 직렬화한다.
업무 요청은 시작 세대를 고정하고 토큰·Claims·health 대기, 응답 및 refresh 후
다시 확인한다. 이전 세대의 응답은 새 세션의 refresh·signOut이나 UI 갱신에
사용하지 않는다. 로컬 취소는 HTTP 401과 구분하며, 이미 전송된 서버 작업을
취소한다고 보장하지 않는다. 명시적 custom tokenLoader 사용자는 자신의
세션 수명주기에 맞는 requestGuard를 주입해야 한다.

Backend의 RETIRED_DATA_RUNS는 사용 완료 Data run을 중앙에서 차단한다.
확인된 rtdb-20261025-6e9a7c42와 부분 사용한 rtdb-20261026-b742c9e1은
일반/ride-only 모두 거부하며,
긍정 등록 목록에 남아 있거나 재등록돼도 실행할 수 없다. Auth run은 퇴역시키지
않는다. 신규 일반 run은 REVIEWED_GENERAL_RUNS, 기존 Auth 재사용 run은
REVIEWED_REUSE_RUNS의 정확한 고정 등록이 필요하다. 이 목록은 Auth 재사용·
ride-only·case·계정·경로의 과거 실행 계약이며, 퇴역을 해제하지 않는다.
Flutter의 과거 계약도 퇴역 검사에서 거부하므로 요청 ID 복구 전에 차단된다.
기존 데이터 유무나 실행 승인·생성 영수증을 증명하지 않는다. 설정 변경, 계획
생성 및 서버 SDK 초기화 전 같은 검사를 한다. 실행 완료 후에는 별도 검토로
중앙 퇴역 목록에 명시적으로 추가해야 한다.

공격 회귀: test/cloud_auth_generation_test.dart 및
backend/api/tests/test_cloud_run_retirement.py. 플랫폼 Fake와 차단된 네트워크를
사용한 오프라인 검증이며 실제 Firebase 이벤트 순서 검증을 의미하지 않는다.

## 로컬 Android 하드웨어 버스 안내 (2026-10-25)

실제 Passenger 앱의 첫 모드 선택 화면에서 **실기기 연동확인**를 엽니다. 이 화면은 별도 임시 앱이 아니며, 서버에 연결하지 않고 실제 BLE/WT901/골전도 입력·출력을 사용합니다.
Android 실행 소스와 com.example.mobi_passenger_app 앱 ID를 추가했습니다. 기존 임시 앱(com.mobi.local.mobi_ble_temp)과 별도로 설치됩니다.

```powershell
cd mobi-smart-transport-ai/apps/passenger_app
flutter pub get
flutter run -d DEVICE_ID --debug
```

Flutter 3.41.6 / Dart 3.11.4, Android SDK 36, JDK 21 환경에서 작업했습니다. 통합 앱의 Android minSdk는 26이며 하드웨어 위치 API는 26~27 fallback을 사용합니다.
Windows 한글 경로에서 기존 voice_aurora.frag 셰이더 도구가 실패하면 저장소 전체를 영문 경로에 두어 같은 명령을 실행합니다. 셰이더 소스/기존 음성 기능을 삭제하지 않습니다.
로컬 SDK 경로, build 폴더, APK, keystore는 소스 업로드 대상이 아닙니다. 단계별 변경은 ajh_2semester 브랜치에서 관리합니다.

### 실제 하드웨어 사용 순서

1. 비콘 A C3:00:00:5C:B9:47, B C3:00:00:5C:B9:48, WT901BLE68 F1:35:40:62:CD:43 전원을 켭니다. 제조사 앱의 센서 연결은 해제합니다.
2. 골전도 이어폰을 휴대폰에 연결하고 앱에서 주변 기기/정확한 위치 권한을 허용합니다. Bluetooth와 위치 기능을 켭니다.
3. 목표 버스를 선택합니다. A=502번 역할, B=511번 역할은 이 기기의 테스트 매핑이며 실제 노선 인증이 아닙니다.
4. 센서를 머리에 고정하고 **센서 연결** 후 정류장에서 도로 정면을 바라본 상태로 **도로 정면을 기준으로 설정**합니다. 장착 방향에 따라 좌우가 반대이면 정지 후 반전 옵션을 사용합니다.
5. **버스 탐색 시작 (5분)**을 누르고 실제 수신을 확인한 다음 **버스 소리 시작**을 누릅니다.
6. 비콘을 왼쪽에서 가까이 이동 → 정면에서 잠시 유지 → 오른쪽으로 멀리 이동합니다. RSSI가 강해질수록 목표음 간격은 짧아지고 약해질수록 길어집니다(약 220~1400ms).
7. 다른 테스트 버스의 신호가 -60dBm 이상이고 목표보다 6dB 이상 강하거나 목표가 미수신이면 오탑승 주의 경고음을 우선합니다. 이때는 해당 비콘을 멀리 두거나 목표 버스를 올바르게 선택합니다.

도로 기준 방향은 왼쪽 접근 -90~-30°, 정면 정차 0°, 오른쪽 출발 +30~+90° 가정입니다. 실제 머리 Yaw를 빼서 이어폰의 5방향 출력을 보정합니다.
정차 추정은 보정 RSSI -55dBm 이상이 1.5초 이상/3샘플 이상 유지되는 조건입니다. 정차 이후 기준 최고 신호보다 8dB 이상 약한 상태가 0.8초 이상/3샘플 이상 유지되면 오른쪽 출발로 추정합니다. 단일 급변에는 전환하지 않습니다.
3초 이상 신호가 끊기거나 버스/탐색을 새로 선택하면 해당 흐름을 초기화합니다. 실제 승차 여부·차량 방위·물리적 정차를 BLE로 확정하지 않습니다.
센서 수신 1초/비콘 수신 3초 이상 지연, 이어폰/오디오 포커스 해제, 화면 이탈, 5분 경과, 기준각/목표 변경 시 소리를 중지합니다. 자동 재시작하지 않습니다.
기존 비콘 진단에서 일반 목표의 상대 방향이 전방 5방향 범위(좌우 5° 여유 포함 ±95°) 밖이면 중지합니다. 비콘으로 판단한 오탑승 경고의 대상이 뒤쪽이면 후방·무방향 경고임을 표시하고 좌우 균등한 경고음을 사용합니다. 아래의 명시적 장애물 HRTF 경고와는 별도 경로입니다.

### Mock 데이터 테스트와의 구분

첫 화면의 Mock 데이터 테스트에서는 기존 예시 시나리오를 사용합니다.
실기기 연동확인에서는 실제 BLE/WT901/골전도 입력·출력을 확인합니다. 기존 시나리오 재생 기능은 없습니다. 별도의 접힌 항목인 '공간 경고음 청취 확인 (검증용)'은 방향 청취만 확인하는 명시적 테스트 입력입니다.
기존 mock_scenario 코드와 예시 정의는 변경하지 않습니다. 목표 버스 변경 시 소리만 정지하며 센서 연결은 유지합니다.

### 검증

```powershell
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
```

Bluetooth는 실제 Android 기기가 필요합니다. 자동 테스트는 가짜 무선 스트림과 네이티브 채널을 사용하므로 실기기 청취 검증과 구분합니다.

2026-10-25 실기기 전용 화면 검증: analyze 문제 없음, 전체 테스트 56개 PASS, Android APK 빌드 및 무선 설치·실행 성공. 기존 web release는 이전 연동 버전 검사 결과입니다. 추가 실기기 청취 검증은 별도입니다.


### 장애물 음향 입력 준비 (로컬 모듈)

`lib/src/features/hardware_bus/obstacle_cue_input.dart`는 향후 식별·위험 판단 결과를 받기 위한 로컬 입력 모델입니다. 식별 코드는 포함하지 않습니다. 실기기 확인 화면에는 선택적 장애물 입력 경로만 연결했으며 실제 입력 생산자는 아직 없습니다. 일반 안내는 입력이 없으면 장애물 경고를 만들지 않습니다. 청취 확인용 입력은 명시적으로 연 검증 패널 안에서만 사용하며 일반 안내에 전달하지 않습니다.

생산자는 전체 장애물 목록을 `ObstacleCueSnapshot`으로 전달합니다. ID, 위험도(none/caution/danger), 도로 정면 기준 방향(오른쪽 양수, -180~180도), 관측 시각이 필요합니다. 위험도는 거리나 RSSI로 추정하지 않습니다. 관측 시각은 CueController의 now와 같은 단조 증가 세션 시계를 사용하며, 재생 시각으로 갱신하지 않습니다. 생산자는 역순 프레임을 버리고 세션 변경 시 목록을 비워야 합니다. 카메라 상대 방향은 촬영 당시 머리 자세로 도로 기준 방향에 변환한 후 전달해야 합니다. 방향을 모르면 0도로 대체하지 않습니다.

`toCueObjects()` 결과를 최신 버스 목표와 함께 기존 CueController에 전달할 수 있습니다. 주의/위험은 버스 목표보다 우선하며, 위험도 없음·미래 시각·2초 이상 지난 장애물은 경고하지 않습니다. 목록에서 사라진 장애물은 다음 판단에서 해제됩니다. 명시적 위험도가 있는 장애물은 후방을 포함한 수평 방향을 HRTF 출력에 전달합니다. 기존 버스 진단의 5방향 정책과 구분합니다.

버스는 기존 target 단일음, 장애물은 warning 이중음 패턴을 사용합니다. 네이티브 출력의 센서 상태·중지 처리는 기존 경로를 재사용합니다. 장애물만으로 출력할 때는 비콘 의존성을 두지 않도록 ToneInput의 beaconAgeMs=-1을 사용해야 합니다. 실제 식별 스트림 연결은 후속 작업이며 이 입력 모델은 팀 공용 API 계약이 아닙니다.


### 비콘과 독립된 장애물 출력 경로

HardwareBusPage의 선택적 obstacles와 sessionNow를 WitSensorPanel을 통해 DirectionAudioPanel로 전달합니다. sessionNow는 관측 시각과 같은 단조 증가 시계여야 합니다. 생산자는 새 전체 스냅샷을 전달할 때 위젯을 갱신합니다. 식별 결과나 시계가 없으면 장애물 입력을 사용하지 않으며 기본 앱은 기존 버스 확인 동작을 유지합니다.

유효한 장애물 입력과 센서 기준각이 있으면 비콘 미수신·버스 비활성 상태에서도 수동으로 안내 소리를 시작할 수 있습니다. 장애물 경고는 네이티브 비콘 watchdog 의존성을 끄고 센서/이어폰/포커스/화면 이탈 중지 처리를 유지합니다. 경고가 해제·만료되면 유효한 버스 안내로 전환하고, 대체 대상이 없으면 중지합니다. 중지 후 새 입력이 와도 자동 재시작하지 않습니다.

2026-11-02 코드 분석 문제 없음, Passenger 앱 전체 자동 테스트 68개 통과. 실제 식별 스트림이나 신규 실기기 청취 검증을 수행했다는 의미는 아닙니다.

### 후방을 포함한 장애물 공간 경고음

SADIE II v2-1 D2 KEMAR 실측 HRIR을 사용해 수평 5도 간격의 경고음을 미리 합성했습니다. 정면과 정후방은 좌우가 균등하지만 서로 다른 실측 필터를 사용합니다. 앞뒤 단서가 없는 순음 대신 광대역 성분을 포함한 이중 경고음을 사용합니다. 나머지 방향은 측정된 귀별 시간·음량 차이를 보존하며, 각도 사이를 보간하고 머리 회전은 약 20ms로 평활화합니다. 버스의 기존 단일음과 좌우 진단 출력은 유지합니다.

데이터와 Apache 2.0 라이선스·출처·변환 내역은 `android/app/src/main/assets/hrtf/`에 있습니다. 실행 중 다운로드나 Python 설치는 필요하지 않습니다. 재생 데이터 재생성에만 `tools/build_spatial_warning_bank.py`와 numpy/scipy/h5py가 필요합니다.

청취 순서: 골전도 이어폰 연결 → 실기기 연동확인 → 권한 허용 → WT901 센서 연결 → 도로 정면 기준 설정 → '공간 경고음 청취 확인 (검증용)' 펼치기 → 정면/정후방/왼쪽/오른쪽 선택 → '안내 소리 시작'. 비콘 탐색은 필요하지 않습니다. 머리를 돌리면 도로 기준 대상의 상대 방향이 바뀝니다. 패널을 닫으면 검증음을 중지하며 일반 안내와 검증 패널은 동시에 재생하지 않습니다.

이 필터는 일반 KEMAR 측정으로 개인화되거나 골전도 전용으로 측정된 것이 아닙니다. 정면/후방 파형 차이와 빌드 성공은 사용자가 뒤쪽으로 느낀다는 증거가 아닙니다. 실제 골전도 이어폰에서 앞뒤 구분은 사용자 청취 결과로 확인해야 합니다.

2026-11-02 사용자 청취에서 후방 방향감은 확인했습니다. 전방 구분이 어렵고 전방·좌우가 작게 들린다는 피드백에 따라 전방/측면에 약 6dB 보정을 적용하고 후방으로 갈수록 보정량을 줄였습니다. 각 방향의 양쪽 귀에 동일한 보정을 적용하여 좌우 단서와 실측 필터의 주파수 특성은 유지합니다. 정후방 PCM은 보정 전과 동일한 것을 체크섬으로 확인했습니다. 보정 후 전방 방향감과 크기는 사용자 재확인 대상입니다.

후속 청취에서 모든 방향이 약간 뒤쪽으로 몰리는 피드백이 있었으나, 추가 확인에서 사용자가 정면은 앞쪽·정후방은 뒤쪽으로 구분되어 들린다고 명시적으로 확인했습니다. 현재 사용자·이어폰 조합의 정면/정후방 청취 확인 결과이며, 모든 각도나 다른 장비의 정확도 검증을 의미하지 않습니다. 구현·출력 검사와 실제 방향 지각 확인을 구분합니다.


## PR #68 + #69 통합 검토본 (2026-11-03)

- 기준: #69 02b9af2 + #68 47cf2f7. main/원격 PR 병합은 별도 승인 전까지 미실행.
- applicationId/namespace는 Firebase 설정과 호환되는 com.example.mobi_passenger_app을 유지한다.
- 일반 MainActivity가 #68 HardwareBusActivity를 상속하여 hardware-tone/permissions와 기존 mobi/local_android_audio를 한 Launcher에서 등록한다. onPause/onDestroy는 두 경로를 모두 정리한다.
- 첫 화면의 실기기 연동확인은 로컬 하드웨어 시연이다. 기존 온라인 Firebase/Lease, LOCAL_DEMO 카메라 음향, 별도 하드웨어 시연은 구분한다.
- #68의 A/B 비콘은 해당 시험 화면만의 테스트 매핑이며 일반 Guidance 비콘 등록으로 자동 반영하지 않는다. HRTF 장애물 입력은 기존 지역 프로토타입 계약이며 실제 Vision 위험 결과를 자동 연결하지 않는다.
- 시험 앱 target/define 검증, debug 전용 제한, offlinevision 인터넷 차단과 Fake Backend 격리는 #69 가드를 그대로 유지한다.
- 카메라 모델과 SafetyInterpreter, guidanceEligible=false는 변경하지 않았다. HRTF 데이터/라이선스와 독립 temporary_test_app을 보존했다.
- 기존 두 PR의 개별 실기기 증거는 통합 APK의 재수락을 대신하지 않는다.

## 로그인 후 홈 화면 점검 (2026-11-13)

- 일반 Android 앱은 기존 Firebase AuthGate로 등록된 승객 계정을 확인한 뒤 홈을 표시합니다. 로그아웃 상태에서 실행하면 로그인 화면이 먼저 나오며, 기존 로그인 세션 복원 정책은 변경하지 않았습니다.
- 홈의 두 주요 기능은 `노선 정보 검색`과 `장애물 탐지`이며, 오른쪽 위 `로그아웃`은 기존 AuthGate의 로그아웃/실패 재시도 처리를 사용합니다.
- 두 기능 버튼에 스크린리더 이름·설명·실행 동작을 제공합니다. Android의 기존 한 번 탭 설명 TTS/빠른 두 번 탭 실행과 TalkBack 실행 동작을 유지합니다.
- 웹 진단 진입 흐름, Firebase 역할 권한, 비전/노선/공간음향 처리 로직은 변경하지 않았습니다. iOS Semantics 테스트는 iOS 앱 포팅이나 실기기 VoiceOver 검증을 의미하지 않습니다.
- 회귀 확인: `flutter test test/passenger_login_home_test.dart test/android_runtime_configuration_test.dart`. 실제 Firebase 로그인과 Android TalkBack/TTS 청취는 실기기에서 별도 확인합니다.

### UI 정리 및 테스트 버튼 분리 (2026-11-13)

기존 카메라 시작/중지, 하단 고정 중지 버튼, 권한 오류 안내, 요청 중복 차단, 경로 응답 TTS, 화면 음향 Hold 기능을 확인한 뒤 중복 구현하지 않았습니다. 로그인은 큰 글씨와 키보드가 열린 화면에서 스크롤 가능하게 하고, 로그인 오류/카메라 상태/서버 오류를 접근성 상태로 노출했습니다. 모드 선택 실패는 화면에 남는 복구 안내를 표시하며 Android 위치 권한 안내를 추가했습니다. 홈 아이콘은 두 주요 기능이 있는 홈으로 돌아갑니다.

제거한 인앱 테스트 버튼:
- 모의 geofence/비콘/탑승 이벤트 주입 11개. 서버 상태 전이·이벤트 입력은 `scripts/smoke_v3_guidance.py` 및 backend 테스트에서 기기 없이 확인 가능합니다. 위젯의 기존 콜백 계약과 서버 로직은 유지하고 버튼 노출만 제거했습니다.
- 사창사거리/충북대병원/상당산성 고정 목적지 테스트 바로가기 3개. 채팅·음성 목적지 입력, 목적지 후보 선택, 경로 안내 시작, 도착정보 갱신은 유지했습니다.

유지한 실기기 점검: BLE 실제 스캔, WT901/HRTF 및 헤드트래킹 보정, 좌우 방향 청취, 한국어 TTS, STOP/세션 종료/백그라운드 잔여음, 시나리오 오디오·Repeat Line. 자동 테스트 통과를 실제 기기·이어폰 청취 완료로 간주하지 않습니다. 안내 반복 간격·Hold의 동작·위험 경보 정책은 변경하지 않았고, 노선 조회 결과를 특정 차량으로 추정 매칭하지 않습니다.

검증용 추가 테스트: `test/passenger_ui_cleanup_test.dart` (모의 버튼 제거/실제 동작 유지, 모드 선택 접근성, 큰 글씨 로그인).

### Route-input fallback regression

- The NLU selector now defaults to the backend's existing `auto` mode (Gemini, then OpenAI fallback), rather than forcing OpenAI. Explicit diagnostic overrides remain available.
- Known place/stop names and explicit route-search phrases are recognized locally when optional NLU is unavailable. Unknown bare place names still need NLU; use an explicit request such as `청주대 가는 버스` or `충북대병원 어떻게 가?`.
- Local regression tests isolate external services. They do not verify deployed API credentials, live transit results, microphone recognition, or on-device playback. No deployment is included.

### Camera direction audio integration (2026-11-14)

The normal camera entry retains selected-object directional audio: three consecutive
frames, verified parent-bus containment for doors, and the existing obstacle-first
selection/preemption policy. Scene-summary mode is not the default. Existing STOP,
Hold, freshness, ownership and authentication/session shutdown remain in force.
Screen directions and bounding-box presentation ranking are not measured road
directions, distance or collision risk. Preview remains guidanceEligible=false.

The separate stationary hardware diagnostic may summarize multiple objects. It
filters doors through the same parent-bus validation before scene summarization;
an unsupported door must not suppress a valid obstacle. This diagnostic is not
automatic navigation or proof of real-device safety. Android and headphone
listening remain separate acceptance tests.

Historical build record (before this integration fix):
Build verification: `:app:compileDebugKotlin` passed offline using the installed Android Studio bundled JDK 21, with explicit `-Ptarget=lib/main.dart`. Set `JAVA_HOME` for the current terminal/process only when reproducing. JDK 23 failed in the existing CameraX Java compiler task before app Kotlin; the same source passed with JDK 21, so no dependency, global Java setting or Gradle configuration change was made. This was compile-only, not APK packaging, installation or listening validation.

### Stationary beacon target-heading demonstration

The hardware screen has an explicit stationary-beacon mode, separate from the simulated left/front/right bus passage. Select the actual beacon, establish the WT sensor reference/sign, then look toward the fixed beacon and press the target-heading calibration button. Start playback separately. Remain in the same location and rotate only the head; if the user or target moves, stop and recalibrate. This feature does not track translation, measure bearing from RSSI, or authenticate a vehicle.

The stored target heading and current head yaw use the same sign/reference convention. Turning the head right moves a fixed forward target to the left output. Existing five-way stereo output is retained; targets outside its supported front/side field do not become fictional rear-direction cues.

RSSI affects cadence only, with per-radio-sample smoothing and a 60 ms interval deadband. The existing provisional bounds are 1,400–220 ms; stronger signal can shorten the interval, but reflections/body blocking mean it does not prove approaching distance. Proximity remains `UNKNOWN`. Target/reference/sign/session changes and lost or stale sensor/beacon data invalidate calibration and stop target playback. Existing explicit obstacle-warning priority is preserved and is not gated on beacon calibration. Recovered data alone must not restart an old calibration.

The normal camera entry preserves the existing obstacle priority policy. Hardware diagnostics remain separate; local tests do not establish APK/device listening or live safety validation.


### Temporary concurrent hardware test

The headphone/device-check screen entry `동시 기기 테스트 (임시)` opens a dedicated, authenticated
Android diagnostic screen. This screen is separate from production route and
obstacle guidance. BLE scan, WT connection and local camera detection have
independent controls; starting one must not unmount or stop another. The compact
`버스·WT` and `카메라` views retain their device state when switching views.
Pairing and extended information are opened explicitly rather than filling a long
main page. Normal phone layouts use no vertical main-page scrolling. At large
accessibility text sizes or short displays, `확대 보기` provides a bounded scrolling
dialog so controls are not clipped; sensor owners remain mounted outside that dialog. Audio
requests are coordinated, not mixed through competing native audio owners.

Enter the test bus number and its confirmed Android beacon MAC in the temporary
screen before starting the scan; it creates no automatic mapping from a bus number.
Enable the bus demonstration voice separately. Camera audio is also opt-in, with
separate start/stop controls and a ping-only option.

The existing 502 / 511 beacon assignments are demonstration roles, not verified
vehicle identities. A matching Android BLE MAC only proves receipt of a configured
demo signal. It cannot establish real bus approach, distance, boarding permission,
or travel safety. Do not use this test screen while navigating traffic.

The integrated camera policy is a controlled, stationary informational scene
summary, not a navigation or hazard-priority system. It groups current reliable
detections into screen left/center/right and reports single, multiple, uncertain
or unavailable scenes. It never estimates physical range from box size or asserts
that a path is clear. `자세히 듣기` describes only the current fresh scene; stale
observations are not queued or replayed. STOP retires pending and active output.

Freshness is based on the application's frame-receipt timestamp, not a verified
camera exposure timestamp. TTS completion events describe software callbacks, not
sound arrival at the listener's ear. Physical audio latency, BLE/camera concurrency
and Shokz stereo perception still require controlled device measurements.
