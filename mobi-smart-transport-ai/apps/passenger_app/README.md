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
