# MOBI Driver App

윤현섭 담당 Flutter 기사 앱 영역입니다.

## 목적

`driver_app`은 버스 기사가 승객 탑승 요청을 확인하고 요청 상태를 갱신하는 기사 전용 앱 스캐폴딩입니다.

## Web Firebase 로그인

새 Firebase 프로젝트에서 Email/Password 로그인을 활성화하고 Driver Web 앱을 등록한다. 로그인은 서버 관리자가 사전 등록한 계정만 가능하다. 실행 시 Console에서 제공한 공개 Web 설정값을 전달한다.

```powershell
flutter pub get
flutter run -d chrome `
  --dart-define=MOBI_API_BASE_URL=http://127.0.0.1:8000 `
  --dart-define=MOBI_FIREBASE_API_KEY=<web-api-key> `
  --dart-define=MOBI_FIREBASE_APP_ID=<driver-web-app-id> `
  --dart-define=MOBI_FIREBASE_MESSAGING_SENDER_ID=<sender-id> `
  --dart-define=MOBI_FIREBASE_PROJECT_ID=<new-project-id> `
  --dart-define=MOBI_FIREBASE_AUTH_DOMAIN=<new-project-id>.firebaseapp.com
```

서버 관리자는 Firebase 계정에 `mobi_role=driver`와 실제 차량 시스템 기사 ID인 `mobi_driver_id`를 별도로 설정해야 한다. 기사는 로그인 후 새 ID token claim에서 매핑값을 읽어 목록 요청의 path에 전달하며, 백엔드가 현재 서버 계정 claim과 다시 대조한다. UID가 기사 ID라고 가정하지 않는다. Admin SDK/service account는 Flutter 앱에 포함되지 않는다.

프로젝트 설정이 없으면 앱은 설정 오류 화면을 표시한다. 보호 HTTP API는 Bearer ID token을 사용하고, 401 재시도 이후에도 거부되면 로그아웃한다. 403 권한 부족과 503 인증 서비스 장애는 구분된다. 이 앱은 웹소켓이나 관리자 endpoint를 사용하지 않는다.

## 4월 구현 범위

- 기사 앱 기본 화면과 라우팅 골격
- 접근성 Semantics 라벨
- 탑승 요청 목록 UI skeleton
- FCM 수신 핸들러와 연계될 알림 UI 구조
- 탑승 요청 상태 변경 버튼/flow skeleton
- 백엔드 API client skeleton 정리

## 기사 앱 API 연동 대상

- `GET /drivers/{driverId}/ride-requests`
- `PATCH /ride-requests/{requestId}/status`

현재 `backend_api_client.dart`는 V2 범위에서 HTTP polling 계약을 검증한다. 요청 목록 새로고침 버튼과 향후 FCM callback은 같은 refresh 경로를 호출하되, FCM 수신 핸들러 자체는 Firebase Messaging 설정이 확정된 뒤 후속 작업으로 연결한다.

## FCM 후속 경계

- HTTP polling: 현재 앱이 직접 실행하는 요청 목록 조회 및 상태 변경 경로이다.
- FCM 클라이언트 수신 핸들러 연동: Firebase Messaging 설정 확정 후 진행할 후속 작업이다.
- FCM 수신 핸들러: 후속 작업에서 push notification setup이 확정되면 새 요청 알림을 받고 기존 HTTP refresh 경로를 깨우는 역할만 맡는다.
- FCM payload parsing, token registration, foreground/background notification 처리는 이번 V2 app integration follow-up 범위에 포함하지 않는다.

## 경계

- 백엔드 로직은 `backend/api`에서 구현한다.
- 공공데이터 API 직접 호출은 하지 않고 백엔드 또는 표준 응답을 통해 받는다.
- BLE/RSSI 로직은 `packages/mobile_sensors`에서 구현한다.
- 사용자 목적지 입력, STT/TTS 기반 사용자 안내, 승객용 지오펜싱 화면은 `apps/passenger_app`에서 다룬다.
- `driver_app`은 `mobi_mobile_sensors`, `flutter_tts`, `speech_to_text`에 직접 의존하지 않는다.

## 탑승 요청 업무 UI 로컬 검증 (2026-10-26)

기존 기사 HomePage와 `/drivers/{driverId}/ride-requests` GET,
`/ride-requests/{requestId}/status` PATCH를 재사용한다. 기사 ID는 현재
인증 계정 Claims에서 조회하며, 인증 오류와 네트워크 오류를 구분해 표시한다.
중복 수락/동시 새로고침을 차단하고 수락 성공 또는 409 충돌 후 목록을 재조회한다.
로그아웃/계정 변경 시 기존 요청을 지우고 이전 계정의 지연 응답을 무시한다.

두 앱을 함께 사용하는 Mock HTTP Widget 검증은 승객 앱의
`test/ride_business_flow_test.dart`에 있다. OFFLINE_UI_E2E이며 실제 Firebase
또는 Chrome 검증과 구분한다. 기존 인증 전용 모드는 기본 OFF를 유지한다.
