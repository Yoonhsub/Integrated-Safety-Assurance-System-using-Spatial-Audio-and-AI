# docs/rw/API_CONTRACTS.md

> MOBI 프로젝트의 API 및 모듈 간 데이터 계약 문서이다.  
> Flutter 앱, FastAPI 백엔드, 공공데이터 모듈, Firebase 구조가 서로 다른 형태로 데이터를 해석하지 않도록 표준 요청/응답 형식을 정의한다.

---

## 1. 기본 원칙

```txt
- API 계약은 임의로 변경하지 않는다.
- 필드명을 바꾸려면 shared contract 변경 PR과 관련 팀원 리뷰가 필요하다.
- 변경이 필요하면 docs/rw/충돌 이슈.md에 기록한다.
- shared_contracts에 반영할 경우 모든 소비 모듈을 확인한다.
- 실제 구현 전 mock JSON도 이 문서와 packages/shared_contracts의 형식을 따른다.
```

---

### OpenAPI 보조 기준

FastAPI의 `/openapi.json`은 자동 생성 클라이언트 참고용이다. 단, `oneOf`, 공백 문자열 금지, date-time format 같은 세부 검증 계약은 `packages/shared_contracts/api/*.schema.json`을 최우선 기준으로 삼는다. OpenAPI 표현과 shared JSON Schema가 충돌하면 shared JSON Schema를 따른다.

## 2. 공통 응답 원칙

### 2.1 성공 응답

본 프로젝트의 성공 응답은 별도의 `success/data/message/timestamp` 래퍼를 사용하지 않는다.

FastAPI 라우트는 `packages/shared_contracts/api/*.schema.json` 및 `backend/api/app/schemas/*.py`에 정의된 응답 객체를 그대로 반환한다.

예:

```json
{
  "stopId": "stop001",
  "arrivals": []
}
```

### 2.2 실패 응답

실패 응답은 FastAPI 기본 오류 형식을 우선 사용한다. 프로젝트 공통 오류 모델이 필요한 경우 아래 형태를 목표로 하되, 성공 응답을 감싸는 wrapper로 확장하지 않는다.

```json
{
  "errorCode": "INVALID_REQUEST",
  "message": "요청값이 올바르지 않습니다.",
  "details": {}
}
```

### 2.3 기준 파일 우선순위

```txt
1. packages/shared_contracts/api/*.schema.json
2. backend/api/app/schemas/*.py
3. docs/rw/API_CONTRACTS.md
4. 각 팀원 프롬프트/보고서 문서
```

위 문서들이 충돌할 경우 shared contract와 Pydantic schema를 먼저 맞춘 뒤, 문서를 동기화한다.

---

## 3. 상태값 공통 규칙

### 3.1 지오펜싱 상태

```txt
SAFE
WARNING
DANGER
OUT_OF_AREA
UNKNOWN
```

### 3.2 rideRequests 상태

```txt
WAITING
NOTIFIED
ACCEPTED
ARRIVED
COMPLETED
CANCELLED
```

### 3.3 혼잡도 상태

```txt
LOW
NORMAL
HIGH
UNKNOWN
```

### 3.4 BLE 신호 상태

```txt
VERY_CLOSE
CLOSE
MEDIUM
FAR
LOST
```

---

## 4. Health Check API

담당: 심현석

```txt
GET /health
```

응답:

```json
{
  "status": "ok",
  "service": "mobi-backend-api"
}
```

---

## 5. Geofence Check API

담당: 심현석  
소비: 윤현섭 사용자 앱

```txt
POST /geofence/check
```

요청:

```json
{
  "userId": "user001",
  "stopId": "stop001",
  "lat": 36.6281,
  "lng": 127.4562,
  "timestamp": "2026-04-18T14:32:00+09:00"
}
```

응답:

```json
{
  "status": "DANGER",
  "message": "위험 구역에 접근 중입니다. 뒤로 물러나세요.",
  "shouldSpeak": true,
  "shouldVibrate": true,
  "eventId": "event001"
}
```

주의:

```txt
- timestamp는 요청 시점 기록용 optional 필드이다.
- eventId는 이벤트가 생성되지 않은 경우 null일 수 있다.
- 윤현섭 에이전트는 이 응답 구조를 임의로 변경하지 않는다.
```

---

## 6. Bus Arrivals Standard Contract

담당: 김도성  
소비: 윤현섭 사용자 앱, 심현석 백엔드 인터페이스

이 계약은 공공데이터 API 원본 응답이 아니라, 프로젝트 내부 표준 응답이다.  
공식 기준 파일은 `packages/shared_contracts/api/bus_arrivals.response.schema.json`이다.

```json
{
  "stopId": "stop001",
  "arrivals": [
    {
      "routeId": "route502",
      "busNo": "502",
      "arrivalMinutes": 3,
      "remainingStops": 2,
      "lowFloor": true,
      "congestion": "NORMAL",
      "updatedAt": "2026-04-18T14:32:00+09:00"
    }
  ]
}
```

필드 설명:

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `stopId` | string | 예 | 정류장 ID |
| `arrivals` | array | 예 | 도착 예정 버스 목록 |
| `routeId` | string | 예 | 노선 ID |
| `busNo` | string | 예 | 버스 번호 |
| `arrivalMinutes` | integer | 예 | 도착 예정 분 |
| `remainingStops` | integer/null | 아니오 | 남은 정류장 수 |
| `lowFloor` | boolean | 예 | 저상버스 여부 |
| `congestion` | enum | 예 | LOW/NORMAL/HIGH/UNKNOWN |
| `updatedAt` | string(date-time) | 예 | 갱신 시각 |

주의:

```txt
- app-facing API 응답에는 stopName과 source를 포함하지 않는다.
- stopName은 /busStops 또는 앱 로컬 캐시의 정류장 메타데이터에서 처리한다.
- 공공데이터 원천/제공처 정보가 필요하면 내부 로그 또는 별도 metadata 구조에 둔다.
```

---

## 7. Bus Arrivals API Interface

담당: 심현석 인터페이스 / 김도성 데이터 모듈

```txt
GET /bus-info/stops/{stopId}/arrivals
```

응답:

```json
{
  "stopId": "stop001",
  "arrivals": [
    {
      "routeId": "route502",
      "busNo": "502",
      "arrivalMinutes": 3,
      "remainingStops": 2,
      "lowFloor": true,
      "congestion": "NORMAL",
      "updatedAt": "2026-04-18T14:32:00+09:00"
    }
  ]
}
```

백엔드 cache 기준:

```txt
Firebase RTDB cache path: /busArrivals/{stopId}
Cache payload shape: BusArrivalsResponse
```

```json
{
  "stopId": "stop001",
  "arrivals": [
    {
      "routeId": "route502",
      "busNo": "502",
      "arrivalMinutes": 3,
      "remainingStops": 2,
      "lowFloor": true,
      "congestion": "NORMAL",
      "updatedAt": "2026-04-18T14:32:00+09:00"
    }
  ]
}
```

심현석 백엔드 인터페이스 정합성 원칙:

```txt
- `/bus-info/stops/{stopId}/arrivals` API 응답과 `/busArrivals/{stopId}` cache payload는 같은 BusArrivalsResponse 구조를 사용한다.
- `/busArrivals/{stopId}/{routeId}` 구조는 사용하지 않는다.
- `routeId`는 `arrivals[]` 내부 필드로 둔다.
- backend는 RTDB cache miss 시 김도성 public_data 모듈의 `BusArrivalsService.get_arrivals(stop_id)`를 호출한다.
- backend는 공공데이터 raw field를 직접 normalize하지 않는다.
- public_data mock 응답과 live 응답은 모두 같은 normalized shape를 반환해야 한다.
```

선행 의존성:

```txt
김도성 섹션 6, 7
→ 심현석 섹션 10, 11
```

---

## 8. Ride Request Create API

담당: 심현석  
소비: 윤현섭 사용자 앱

```txt
POST /ride-requests
```

요청:

```json
{
  "userId": "user001",
  "stopId": "stop001",
  "routeId": "route502",
  "busNo": "502",
  "targetDriverId": "driver001"
}
```

응답:

```json
{
  "requestId": "request001",
  "userId": "user001",
  "stopId": "stop001",
  "routeId": "route502",
  "busNo": "502",
  "targetDriverId": "driver001",
  "status": "WAITING",
  "createdAt": "2026-04-18T14:32:00+09:00",
  "updatedAt": null
}
```

---

## 9. Ride Request Read API

```txt
GET /ride-requests/{requestId}
```

응답:

```json
{
  "requestId": "request001",
  "userId": "user001",
  "stopId": "stop001",
  "routeId": "route502",
  "busNo": "502",
  "targetDriverId": "driver001",
  "status": "NOTIFIED",
  "createdAt": "2026-04-18T14:32:00+09:00",
  "updatedAt": "2026-04-18T14:33:00+09:00"
}
```

---

## 10. Ride Request Status Update API

```txt
PATCH /ride-requests/{requestId}/status
```

요청:

```json
{
  "status": "ACCEPTED"
}
```

응답:

```json
{
  "requestId": "request001",
  "userId": "user001",
  "stopId": "stop001",
  "routeId": "route502",
  "busNo": "502",
  "targetDriverId": "driver001",
  "status": "ACCEPTED",
  "createdAt": "2026-04-18T14:32:00+09:00",
  "updatedAt": "2026-04-18T14:34:00+09:00"
}
```

주의:

```txt
status enum은 심현석 담당 계약이다.
윤현섭 기사용 UI는 이 enum을 임의로 변경하지 않는다.
```

---

## 11. Driver Ride Requests API

담당: 심현석  
소비: 윤현섭 기사용 앱

```txt
GET /drivers/{driverId}/ride-requests
```

응답:

```json
{
  "driverId": "driver001",
  "requests": [
    {
      "requestId": "request001",
      "userId": "user001",
      "stopId": "stop001",
      "routeId": "route502",
      "busNo": "502",
      "targetDriverId": "driver001",
      "status": "WAITING",
      "createdAt": "2026-04-18T14:32:00+09:00",
      "updatedAt": null
    }
  ]
}
```

선행 의존성:

```txt
심현석 섹션 8, 9
→ 윤현섭 섹션 8, 9
```

---

## 12. FCM Notification Contract

담당: 심현석

```txt
POST /notifications/send
```

요청:

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

응답:

```json
{
  "accepted": false,
  "messageId": null,
  "detail": "FCM 전송은 아직 구현되지 않았습니다."
}
```

알림 타입:

```txt
SAFETY_ALERT
RIDE_REQUEST
SYSTEM
```

주의:

```txt
- targetUserId와 targetDriverId 중 정확히 하나만 지정해야 한다.
- 안전 경고는 targetUserId를, 탑승 요청은 targetDriverId를 우선 사용한다.
```

---

## 13. BLE/RSSI Sensor Contract

담당: 안준환  
향후 소비: 윤현섭 앱, 공간음향 모듈

```json
{
  "beaconId": "MOBI_BEACON_001",
  "rssi": -67,
  "estimatedDistanceMeters": 2.8,
  "signalLevel": "CLOSE",
  "lastDetectedAt": "2026-04-18T14:32:00+09:00"
}
```

공식 enum 직렬화 값:

```txt
VERY_CLOSE, CLOSE, MEDIUM, FAR, LOST
```

주의:

```txt
- Dart 모델 필드명도 `signalLevel`을 사용한다. `level` 별칭을 공식 계약으로 쓰지 않는다.
- Dart enum은 JSON 직렬화 시 `veryClose`가 아니라 `VERY_CLOSE`로 변환한다.
- 4월에는 헤드트래킹 값을 포함하지 않는다.
- 헤드트래킹 필드는 future_modules/head_tracking 구현 전까지 추가하지 않는다.
```

---

## 14. Compass/Direction Sensor Contract

담당: 안준환

```json
{
  "headingDegrees": 132.5,
  "accuracy": "MEDIUM",
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

공식 accuracy enum 값:

```txt
HIGH, MEDIUM, LOW, UNKNOWN
```

주의:

```txt
- `accuracy`는 double이 아니라 문자열 enum이다.
- Dart 모델은 `updatedAt` 필드명을 사용한다. `timestamp` 별칭을 공식 계약으로 쓰지 않는다.
```

---

## 15. AI Vision Future Contract

담당: 김도성  
상태: 4월에는 초안만

향후 예상 출력:

```json
{
  "frameId": "frame001",
  "detections": [
    {
      "className": "bus",
      "confidence": 0.92,
      "bbox": {
        "x": 120,
        "y": 80,
        "width": 220,
        "height": 140
      }
    }
  ],
  "processedAt": "2026-09-01T12:00:00+09:00"
}
```

4월에는 이 계약을 확정하지 않는다.  
AI 비전 파트는 데이터 수집 계획과 모델 리서치에 집중한다.


## Machine-readable Ride Request Schemas

```txt
POST /ride-requests request body: packages/shared_contracts/api/ride_request.create.request.schema.json
PATCH /ride-requests/{requestId}/status request body: packages/shared_contracts/api/ride_request.status_update.request.schema.json
Ride request record response: packages/shared_contracts/api/ride_request.schema.json
```
