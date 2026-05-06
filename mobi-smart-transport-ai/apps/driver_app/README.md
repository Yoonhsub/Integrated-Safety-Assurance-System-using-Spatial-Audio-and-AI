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

- FCM 클라이언트 수신 핸들러 연동
- `GET /drivers/{driverId}/ride-requests`
- `PATCH /ride-requests/{requestId}/status`

현재 `backend_api_client.dart`는 병렬 개발용 TODO skeleton이며, 실제 HTTP/FCM 연동은 shared API 계약과 백엔드 산출물을 확인한 뒤 구현한다.

## 경계

- 백엔드 로직은 `backend/api`에서 구현한다.
- 공공데이터 API 직접 호출은 하지 않고 백엔드 또는 표준 응답을 통해 받는다.
- BLE/RSSI 로직은 `packages/mobile_sensors`에서 구현한다.
- 사용자 목적지 입력, STT/TTS 기반 사용자 안내, 승객용 지오펜싱 화면은 `apps/passenger_app`에서 다룬다.
- `driver_app`은 `mobi_mobile_sensors`, `flutter_tts`, `speech_to_text`에 직접 의존하지 않는다.
