# Backend API - 심현석 담당 영역

FastAPI 기반 백엔드입니다.

## 4월 구현 범위

- Firebase Admin SDK 연결
- Realtime Database 스키마/접속 구조
- 지오펜싱 판별 API
- FCM 토큰 저장 및 알림 전송 인터페이스
- 기사-승객 rideRequests 매칭 파이프라인
- 김도성의 공공데이터 결과를 받을 `bus_info_gateway` 인터페이스

## 제외 범위

- 공공데이터 API 직접 호출 구현은 김도성 담당입니다.
- Flutter UI 구현은 윤현섭 담당입니다.
- BLE/RSSI 구현은 안준환 담당입니다.

## 섹션 2 기준 실행/구조

### 로컬 실행

```bash
cd backend/api
pip install -r requirements.txt
uvicorn app.main:app --reload
```

헬스체크:

```bash
curl http://127.0.0.1:8000/health
```

예상 응답에는 `status`, `service`, `environment`, `firebaseMode`가 포함된다.

### Firebase 연결 원칙

- Firebase Admin SDK는 `app.services.firebase_client.FirebaseClient`에서만 초기화한다.
- `FIREBASE_PROJECT_ID`, `FIREBASE_DATABASE_URL`, `FIREBASE_SERVICE_ACCOUNT_PATH`가 모두 준비되고 `USE_MOCK_DATA=false`일 때만 실제 Admin SDK 초기화를 시도한다.
- 인증 정보가 없거나 개발/mock 모드이면 import 단계에서 실패하지 않고 in-memory RTDB fallback을 사용한다.
- 실제 service account JSON과 `.env`는 저장소에 커밋하지 않는다.

### 테스트

```bash
cd backend/api
PYTHONDONTWRITEBYTECODE=1 PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest tests -q -p no:cacheprovider
```

Windows PowerShell:

```powershell
cd backend/api
$env:PYTHONDONTWRITEBYTECODE="1"
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD="1"
python -m pytest tests -q -p no:cacheprovider
Remove-Item Env:PYTHONDONTWRITEBYTECODE
Remove-Item Env:PYTEST_DISABLE_PLUGIN_AUTOLOAD
```

## 섹션 4 기준 지오펜싱 API 구조

### 엔드포인트

```txt
POST /geofence/check
```

요청 본문은 `GeofenceCheckRequest`를 따른다.

```json
{
  "userId": "user001",
  "stopId": "stop001",
  "lat": 36.6281,
  "lng": 127.4562,
  "timestamp": "2026-04-18T14:32:00+09:00"
}
```

응답 본문은 `GeofenceCheckResponse`를 따른다.

```json
{
  "status": "SAFE",
  "message": "안전 구역 안에 있습니다.",
  "shouldSpeak": false,
  "shouldVibrate": false,
  "eventId": null
}
```

### 판별 원칙

- 상태 enum은 `SAFE`, `WARNING`, `DANGER`, `OUT_OF_AREA`, `UNKNOWN`만 사용한다.
- RTDB `/geofences/{stopId}`가 있으면 해당 polygon 데이터를 우선 사용한다.
- RTDB 데이터가 없으면 개발/테스트용 `MOCK_GEOFENCES` fixture를 사용한다.
- danger zone, warning zone, safe zone 순서로 판별한다.
- safe zone은 존재하지만 어느 zone에도 포함되지 않으면 `OUT_OF_AREA`로 판정한다.
- geofence 데이터 자체가 없으면 `UNKNOWN`으로 판정한다.

### 저장 구조

- 최근 위치는 기존 공식 경로인 `/users/{userId}/currentLocation`에 저장한다.
- 상태 전이 이벤트는 기존 공식 경로인 `/systemLogs/{logId}`에 `GEOFENCE_ALERT` 타입으로 저장한다.
- 섹션 5 검토에서 동일 사용자·정류장에 같은 경고 상태가 반복될 경우 중복 이벤트를 만들지 않도록 보정했다. 최초 경고 상태 또는 이전 상태와 현재 상태가 달라진 경우에만 이벤트를 남긴다.
- 이벤트 level은 `DANGER` → `ERROR`, `WARNING`/`OUT_OF_AREA` → `WARNING`, 그 외 상태 전이 → `INFO`로 기록한다.
- 섹션 4~5에서는 신규 RTDB top-level path를 추가하지 않았다. 최근 상태는 `GeofenceService`의 내부 상태 캐시로 전이 여부를 판별하고, 영속 이벤트는 `/systemLogs`에 남긴다.
- 실제 FCM 알림 전송은 섹션 6 범위이므로 섹션 4~5에서는 호출하지 않는다.


## 섹션 6 기준 FCM 토큰·알림 구조

### 엔드포인트

```txt
POST /notifications/send
```

요청 본문은 `NotificationRequest`를 따른다.

```json
{
  "targetUserId": "user001",
  "targetDriverId": null,
  "type": "SAFETY_ALERT",
  "title": "안전 경고",
  "body": "위험 구역에 접근 중입니다. 뒤로 물러나세요.",
  "data": {
    "stopId": "stop001",
    "geofenceStatus": "DANGER"
  }
}
```

응답 본문은 `NotificationResponse`를 따른다.

```json
{
  "accepted": true,
  "messageId": "mock-fcm-users-user001-...",
  "detail": "Mock FCM send accepted. Real Firebase Messaging was not used."
}
```

### 토큰 저장 원칙

- 공식 FCM 토큰 저장 경로는 `/fcmTokens/{ownerType}/{ownerId}` 하나만 사용한다.
- `ownerType`은 `users` 또는 `drivers`만 허용한다.
- `/users/{userId}/fcmToken`, `/drivers/{driverId}/fcmToken` 같은 중복 저장 필드는 만들지 않는다.
- Flutter 앱은 Firebase Auth 로그인 후 자기 `auth.uid`와 동일한 `ownerId` 경로에 직접 토큰을 등록한다.
- 백엔드는 `FcmService`에서 해당 토큰을 조회해 단일 대상 알림을 전송한다.

### mock 전송 원칙

- `FCM_ENABLED=false`이거나 Firebase Admin SDK가 mock mode이면 실제 Firebase Messaging을 호출하지 않는다.
- 토큰이 존재하는 경우 mock message id를 포함한 `accepted=true` 응답을 반환한다.
- 토큰이 없으면 `accepted=false`와 누락된 `/fcmTokens/...` 경로를 detail에 반환한다.
- 실제 FCM 인증정보가 없어도 import와 테스트가 실패하지 않아야 한다.

### 서비스 helper

`app.services.fcm_service.FcmService`는 다음 helper를 제공한다.

```txt
save_token(owner_type, owner_id, token, platform)
get_user_token(user_id)
get_driver_token(driver_id)
send_safety_alert(user_id, stop_id, geofence_status)
send_ride_request_notification(driver_id, request_id, user_id, stop_id, route_id, bus_no)
```

섹션 6에서는 지오펜싱/rideRequests 흐름에 직접 강결합하지 않고, 섹션 8에서 rideRequests 파이프라인을 만들 때 `send_ride_request_notification`을 연결할 수 있도록 service method까지만 준비한다.


## 섹션 7 기준 FCM 검토·패치 결과

섹션 7에서는 섹션 6 FCM 토큰·알림 구조를 재검토하고, 코드 구조는 유지하되 회귀 방지 테스트와 문서 기록을 보강했다.

검토 결과:

- 공식 토큰 경로는 계속 `/fcmTokens/{ownerType}/{ownerId}` 하나만 사용한다.
- `ownerType`은 `users` 또는 `drivers`만 사용한다.
- `/users/{userId}/fcmToken`, `/drivers/{driverId}/fcmToken` 중복 저장 필드는 만들지 않는다.
- `NotificationRequest`는 `targetUserId`와 `targetDriverId` 중 정확히 하나만 허용한다.
- `data` payload는 Firebase Messaging과 shared schema 양쪽에서 공유 가능한 `dict[str, str]` 형태로 제한한다.
- Firebase 인증정보가 없거나 `FCM_ENABLED=false`이면 mock 전송 결과를 반환한다.
- 섹션 7에서는 rideRequests 저장/상태 변경 파이프라인을 구현하지 않았다. 탑승 요청 생성 시 기사 알림 helper를 연결하는 작업은 섹션 8 범위로 남긴다.

추가 검증:

- 두 target이 동시에 들어온 알림 요청은 422로 거부한다.
- target이 하나도 없는 알림 요청은 422로 거부한다.
- `data` payload 값이 문자열이 아니면 422로 거부한다.

## 섹션 8 기준 rideRequests 매칭 파이프라인

### 엔드포인트

```txt
POST /ride-requests
GET /ride-requests/{requestId}
PATCH /ride-requests/{requestId}/status
GET /drivers/{driverId}/ride-requests
```

### 저장 원칙

- 공식 저장 경로는 `/rideRequests/{requestId}`이다.
- RTDB key가 `requestId`이므로 value 내부에는 `requestId`를 중복 저장하지 않는다.
- API 응답에서는 Flutter 앱이 사용할 수 있도록 `requestId`를 포함해 반환한다.
- 저장 value는 `userId`, `stopId`, `routeId`, `busNo`, `targetDriverId`, `status`, `createdAt`, `updatedAt`만 포함한다.

### 생성 및 알림 연결

- 탑승 요청 생성 시 기본 상태는 `WAITING`이다.
- `targetDriverId`가 있고 해당 기사 FCM 토큰이 `/fcmTokens/drivers/{driverId}`에 있으면 `FcmService.send_ride_request_notification()`을 호출한다.
- mock 또는 실제 FCM 전송이 accepted이면 상태를 `NOTIFIED`로 갱신한다.
- 기사 FCM 토큰이 없거나 알림 전송이 실패해도 `/rideRequests/{requestId}` 저장 자체는 실패시키지 않고 `WAITING` 상태로 유지한다.

### 조회 및 상태 변경

- `GET /ride-requests/{requestId}`는 RTDB value에 key의 `requestId`를 합쳐 shared `RideRequest` 응답으로 반환한다.
- `PATCH /ride-requests/{requestId}/status`는 `WAITING`, `NOTIFIED`, `ACCEPTED`, `ARRIVED`, `COMPLETED`, `CANCELLED` enum만 허용한다.
- `GET /drivers/{driverId}/ride-requests`는 `/rideRequests` 전체에서 `targetDriverId == driverId`인 요청만 필터링해 반환한다.

### 범위 제한

- 기사 앱 UI는 구현하지 않는다.
- 공공데이터 API 구현과 버스 도착 정보 산출은 섞지 않는다.
- shared contracts와 Firebase schema/rules는 기존 계약이 충분하므로 수정하지 않는다.

## Section 9 — rideRequests 검토 및 회귀 테스트 보강

섹션 9에서는 섹션 8의 rideRequests 파이프라인을 재검토했다. 코드 구조는 유지하되, 다음 회귀 테스트를 추가해 후속 Flutter 기사 앱 연동 시 데이터 계약이 흔들리지 않도록 했다.

- `PATCH /ride-requests/{requestId}/status`가 shared schema에 없는 status 값을 거부하는지 확인한다.
- `GET /drivers/{driverId}/ride-requests`가 `targetDriverId` 기준으로 다른 기사 요청을 제외하는지 확인한다.
- 기사별 요청 목록이 최신 생성 요청부터 반환되는지 확인한다.
- RTDB 저장 구조는 계속 `/rideRequests/{requestId}`이며 value 내부에는 `requestId`를 중복 저장하지 않는다.

이번 검토에서는 `shared_contracts`, Firebase schema/rules, Flutter UI, public_data 영역을 수정하지 않았다.

## Section 10 — bus_info_gateway 공공데이터 연동 인터페이스

섹션 10에서는 김도성 `services/public_data` 모듈을 직접 수정하지 않고, FastAPI 쪽 gateway 경계만 구현했다.

### 엔드포인트

```txt
GET /bus-info/stops/{stopId}/arrivals
```

응답은 `packages/shared_contracts/api/bus_arrivals.response.schema.json`과 같은 표준 필드만 사용한다.

```json
{
  "stopId": "mock-stop-001",
  "arrivals": [
    {
      "routeId": "MOCK-502",
      "busNo": "502",
      "arrivalMinutes": 3,
      "remainingStops": 2,
      "lowFloor": true,
      "congestion": "UNKNOWN",
      "updatedAt": "2026-04-01T00:00:00Z"
    }
  ]
}
```

### 조회 순서

1. `/busArrivals/{stopId}`에 저장된 Firebase RTDB cache를 먼저 조회한다.
2. cache가 없으면 `services/public_data/examples/mock_bus_arrivals.json`을 읽기 전용 fallback으로 사용한다.
3. cache와 mock 모두 해당 `stopId`를 제공하지 않으면 `{"stopId": stopId, "arrivals": []}`를 반환한다.

### 범위 제한

- 공공데이터 API 직접 호출을 구현하지 않는다.
- `services/public_data/**` 파일은 수정하지 않는다.
- 저상버스 여부, 혼잡도, provider-specific raw field를 backend에서 새로 계산하지 않는다.
- shared schema에 없는 필드는 응답에 추가하지 않는다.
- 김도성 섹션 6, 7 표준화 완료 전까지 실제 provider 연동은 TODO 상태로 둔다.

### Firebase gateway 인터페이스

- gateway cache 경로는 `/busArrivals/{stopId}`이다.
- cache payload는 `BusArrivalsResponse`와 같은 normalized shape를 사용한다.
- backend service는 이미 normalized된 응답을 저장·조회할 수 있지만, raw public data normalize는 김도성 담당 범위이다.


## Section 11 — bus_info_gateway 제한적 검토 및 선행의존성 대기 기록

섹션 11에서는 섹션 10의 `bus_info_gateway` 산출물을 검토했다. 김도성 섹션 6, 7이 아직 미구현 상태이므로 실제 공공데이터 provider 연동 확정은 진행하지 않았고, 다음 제한적 범위만 확인했다.

### 검토 결과

- `GET /bus-info/stops/{stopId}/arrivals`는 공공데이터 API를 직접 호출하지 않는다.
- `services/public_data/**` 내부 파일을 수정하지 않는다.
- RTDB cache 경로는 `/busArrivals/{stopId}`로 유지한다.
- cache payload는 `BusArrivalsResponse` normalized shape만 사용한다.
- `BusInfoGatewayService.save_arrivals()`는 provider-specific raw field를 저장하지 않는다.
- shared schema에 없는 `rawData`, `busType`, `reride_Num` 같은 필드는 backend gateway에서 확정하지 않는다.
- cache가 없으면 public_data mock JSON을 읽기 전용 fallback으로만 참조한다.

### 조건부 완료 상태

현재 `bus_info_gateway`는 shared schema와 mock/cache 기반 placeholder gateway interface로만 완료되었다. 실제 provider 연동, 저상버스 표준화 규칙, 혼잡도 표준화 규칙, public_data normalize 함수와의 직접 연결은 김도성 섹션 6, 7 완료 후 통합 검수 단계에서 재확인해야 한다.

### 후속 통합 TODO

- 김도성 섹션 6, 7 완료 후 `services/public_data` 표준화 함수 출력이 `BusArrivalsResponse`와 일치하는지 확인한다.
- 추가 필드가 필요하면 backend에서 임의 확정하지 말고 shared contract 변경 PR 및 충돌 이슈 기록을 먼저 진행한다.
- 통합 검수·패치 단계에서 public_data → backend gateway → Flutter bus card까지 DTO 정합성을 재검토한다.
