# MOBI Driver App

윤현섭 담당 Flutter 기사 앱 영역입니다.

## 목적

`driver_app`은 버스 기사가 승객 탑승 요청을 확인하고 요청 상태를 갱신하는 기사 전용 앱 스캐폴딩입니다.

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
