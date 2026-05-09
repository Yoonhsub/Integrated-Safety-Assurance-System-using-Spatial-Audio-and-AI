# docs/rw/DATA_SCHEMA.md

> MOBI 프로젝트의 Firebase Realtime Database 및 내부 데이터 구조 명세 문서이다.  
> 이 문서는 백엔드, Flutter 앱, 공공데이터 모듈, 기사-승객 매칭 기능이 동일한 데이터 구조를 참조하도록 하기 위해 작성되었다.

---

## 1. 기본 원칙

```txt
- Firebase 경로는 임의로 변경하지 않는다.
- app-facing 필드명은 docs/rw/API_CONTRACTS.md 및 packages/shared_contracts와 일치시킨다.
- 변경이 필요하면 docs/rw/충돌 이슈.md에 기록한다.
- shared_contracts와 불일치하면 PR 병합을 보류한다.
- 개인정보와 위치 정보는 최소한으로 저장한다.
```

---

## 2. 최상위 경로

```txt
/users
/drivers
/busStops
/geofences
/busArrivals
/rideRequests
/fcmTokens
/systemLogs
```

### FCM 토큰 저장 원칙

FCM 토큰은 `/users/{userId}/fcmToken` 또는 `/drivers/{driverId}/fcmToken`에 중복 저장하지 않는다.
공식 저장 위치는 `/fcmTokens/{ownerType}/{ownerId}` 하나이며, `ownerType`은 `users` 또는 `drivers`만 사용한다.

FCM 토큰 등록 책임은 Flutter 클라이언트에 있다. 각 앱은 Firebase Auth 로그인 후 자신의 `auth.uid`와 동일한 `ownerId` 경로에 직접 write한다.

- 승객 앱: `/fcmTokens/users/{auth.uid}`
- 기사 앱: `/fcmTokens/drivers/{auth.uid}`

백엔드는 Firebase Admin SDK로 위 경로의 토큰을 조회해 FCM 알림을 발송한다.
사용자/기사 프로필 문서는 표시명, 유형, 위치, 상태 등 프로필 데이터만 보관한다.

---

## 3. users

경로:

```txt
/users/{userId}
```

예시:

```json
{
  "role": "passenger",
  "displayName": "사용자",
  "userType": "visually_impaired",
  "currentLocation": {
    "lat": 36.6281,
    "lng": 127.4562,
    "updatedAt": "2026-04-18T14:32:00+09:00"
  },
  "createdAt": "2026-04-18T14:00:00+09:00",
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

필드:

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `role` | string | 예 | passenger, driver, admin |
| `displayName` | string | 아니오 | 사용자 표시명 |
| `userType` | string | 아니오 | visually_impaired, elderly, general, unknown |
| `currentLocation` | object | 아니오 | 최근 위치 |
| `createdAt` | string | 예 | 생성 시각 |
| `updatedAt` | string | 예 | 갱신 시각 |

---

## 4. drivers

경로:

```txt
/drivers/{driverId}
```

4월 MVP에서 `driverId`는 Firebase Auth UID와 동일하게 사용한다. 즉, 기사 계정은 `/users/{driverId}.role = "driver"`로 관리하고, 운행 정보는 `/drivers/{driverId}`에 저장한다. Firebase rules의 기사 위치 write 권한도 `auth.uid === driverId`를 전제로 한다. 독립적인 운수사 내부 기사번호가 필요할 경우 별도 필드로 추가하고, RTDB key로 사용하지 않는다.

예시:

```json
{
  "busNo": "502",
  "routeId": "route502",
  "currentLocation": {
    "lat": 36.6285,
    "lng": 127.4568,
    "updatedAt": "2026-04-18T14:32:00+09:00"
  },
  "status": "ACTIVE",
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

주의: `drivers`에는 운행 관련 필드만 둔다. 기사 표시명, 사용자/기사 role, 계정 생성 시각은 `/users/{userId}` 또는 인증/관리자 계층에서 관리한다.

---

## 5. busStops

경로:

```txt
/busStops/{stopId}
```

예시:

```json
{
  "name": "충북대학교 정문",
  "lat": 36.6281,
  "lng": 127.4562,
  "description": "정문 인근 버스 정류장"
}
```

주의: 정류장 메타데이터의 생성/갱신 시각을 저장하기로 확정하기 전까지 `busStops` 공식 RTDB schema에는 `createdAt`, `updatedAt`을 두지 않는다.

---

## 6. geofences

경로:

```txt
/geofences/{stopId}
```

공식 RTDB 구조:

```json
{
  "safeZone": [
    { "lat": 36.6281, "lng": 127.4562 },
    { "lat": 36.6282, "lng": 127.4563 }
  ],
  "warningZones": [
    {
      "name": "정류장 경계 주의 구역",
      "polygon": [
        { "lat": 36.6283, "lng": 127.4564 }
      ]
    }
  ],
  "dangerZones": [
    {
      "name": "차도 방향",
      "polygon": [
        { "lat": 36.6284, "lng": 127.4565 }
      ]
    }
  ],
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

주의:

```txt
- `infrastructure/firebase/realtime_database.schema.json`의 배열 기반 구조를 공식 기준으로 한다.
- safeZone은 polygon 좌표 배열이다. 별도 `{type, coordinates}` 래퍼를 두지 않는다.
- warningZones/dangerZones는 `{name, polygon}` 구조를 사용한다.
- 정확한 polygon 데이터는 테스트 환경에 맞게 추후 조정한다.
- 4월에는 구조와 판별 인터페이스를 우선한다.
```


---

## 7. busArrivals

경로:

```txt
/busArrivals/{stopId}
```

설명:

```txt
busArrivals는 공공데이터 원본을 그대로 저장하는 영역이 아니라,
심현석 백엔드 bus_info_gateway가 조회하는 정류장별 도착 정보 cache이다.

저장 payload는 앱에 노출되는 표준 응답인 BusArrivalsResponse와 같은 normalized shape를 사용한다.
즉, Firebase RTDB cache와 `GET /bus-info/stops/{stopId}/arrivals` 응답은 같은 구조를 공유한다.
```

예시:

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
    },
    {
      "routeId": "route713",
      "busNo": "713",
      "arrivalMinutes": 9,
      "remainingStops": null,
      "lowFloor": false,
      "congestion": "UNKNOWN",
      "updatedAt": "2026-04-18T14:32:00+09:00"
    }
  ]
}
```

필드 설명:

| 필드 | 타입 | 필수 | 설명 |
|---|---|---:|---|
| `stopId` | string | 예 | 정류장 ID. RTDB path의 `{stopId}`와 같아야 한다. |
| `arrivals` | array | 예 | 해당 정류장의 도착 예정 버스 목록 |
| `arrivals[].routeId` | string | 예 | 노선 ID |
| `arrivals[].busNo` | string | 예 | 사용자에게 표시할 버스 번호 |
| `arrivals[].arrivalMinutes` | integer | 예 | 도착 예정 분. 0 이상 |
| `arrivals[].remainingStops` | integer/null | 아니오 | 남은 정류장 수. 제공처에서 없으면 null |
| `arrivals[].lowFloor` | boolean | 예 | 저상버스 여부 |
| `arrivals[].congestion` | enum | 예 | `LOW`, `NORMAL`, `HIGH`, `UNKNOWN` |
| `arrivals[].updatedAt` | string(date-time) | 예 | 도착 정보 갱신 시각 |

담당 경계:

```txt
- 김도성: 공공데이터 API 원본 조회 및 BusArrivalsResponse normalized shape로 표준화
- 심현석: `/busArrivals/{stopId}` cache 저장/조회 인터페이스와 `/bus-info/stops/{stopId}/arrivals` API 전달
- 윤현섭: `/bus-info/stops/{stopId}/arrivals` 응답 또는 같은 shape의 mock 응답 렌더링
```

정합성 기준:

```txt
- `/busArrivals/{stopId}/{routeId}` 구조는 사용하지 않는다.
- `routeId`는 `arrivals[]` 내부 필드로만 둔다.
- backend cache에는 공공데이터 원본 필드, provider-specific raw field, rawData를 저장하지 않는다.
- app-facing API 응답에는 stopName, source, provider metadata를 포함하지 않는다.
- stopName은 `/busStops` 또는 앱 로컬 캐시에서 처리한다.
- 도착 예정 순서는 `arrivals` 배열 순서로 보존한다.
```

---

## 8. rideRequests

경로:

```txt
/rideRequests/{requestId}
```

예시:

```json
{
  "userId": "user001",
  "stopId": "stop001",
  "routeId": "route502",
  "busNo": "502",
  "targetDriverId": "driver001",
  "status": "WAITING",
  "createdAt": "2026-04-18T14:32:00+09:00",
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

status enum:

```txt
WAITING
NOTIFIED
ACCEPTED
ARRIVED
COMPLETED
CANCELLED
```

상태 전이 권장:

```txt
WAITING
→ NOTIFIED
→ ACCEPTED
→ ARRIVED
→ COMPLETED
```

취소:

```txt
WAITING/NOTIFIED/ACCEPTED
→ CANCELLED
```

---

## 9. fcmTokens

경로:

```txt
/fcmTokens/{ownerType}/{ownerId}
```

예시:

```json
{
  "token": "fcm_token_example",
  "platform": "android",
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

ownerType:

```txt
users
drivers
```

---

## 10. systemLogs

경로:

```txt
/systemLogs/{logId}
```

예시:

```json
{
  "type": "GEOFENCE_ALERT",
  "level": "INFO",
  "message": "DANGER status detected for user001",
  "relatedUserId": "user001",
  "relatedRequestId": null,
  "createdAt": "2026-04-18T14:32:00+09:00"
}
```

4월에는 필수 구현이 아니라 향후 디버깅을 위한 선택 구조이다.

---

## 11. 내부 모델: GeofenceResult

```json
{
  "userId": "user001",
  "stopId": "stop001",
  "status": "DANGER",
  "message": "위험 구역에 접근 중입니다. 뒤로 물러나세요.",
  "shouldSpeak": true,
  "shouldVibrate": true,
  "distanceToDangerZoneMeters": 1.4,
  "evaluatedAt": "2026-04-18T14:32:00+09:00"
}
```

---

## 12. 내부 모델: BusArrival

```json
{
  "routeId": "route502",
  "busNo": "502",
  "arrivalMinutes": 3,
  "remainingStops": 2,
  "lowFloor": true,
  "congestion": "NORMAL",
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

---

## 13. 내부 모델: BeaconSignal

```json
{
  "beaconId": "MOBI_BEACON_001",
  "rssi": -67,
  "estimatedDistanceMeters": 2.8,
  "signalLevel": "CLOSE",
  "lastDetectedAt": "2026-04-18T14:32:00+09:00"
}
```

---

## 14. 개인정보 및 위치 정보 처리 원칙

```txt
- 주민등록번호, 상세 주소 등 민감 개인정보 저장 금지
- 위치 정보는 서비스 기능에 필요한 최소 범위로만 저장
- currentLocation은 최신값 위주로 관리
- 테스트 데이터에는 실제 개인정보 사용 금지
- 공개 저장소에 Firebase service account key 업로드 금지
```

---

## 15. 스키마 변경 절차

스키마를 변경해야 한다면 다음 절차를 따른다.

```txt
1. 변경 필요성 확인
2. 영향받는 API/앱/서비스 확인
3. docs/rw/충돌 이슈.md 기록
4. 관련 팀원 협의
5. docs/rw/DATA_SCHEMA.md 수정
6. docs/rw/API_CONTRACTS.md 수정 필요 여부 확인
7. shared_contracts 수정
8. PR 생성
```

---

## 16. 4월 기준 확정/보류 구분

확정에 가까운 구조:

```txt
/users
/drivers
/busStops
/geofences
/busArrivals
/rideRequests
/fcmTokens
```

보류 또는 향후 확장:

```txt
/systemLogs
AI vision result schema
head tracking schema
spatial audio event schema
```

---

## 17. 최종 원칙

```txt
DB 경로는 적게 만든다.
필드명은 계약 문서와 맞춘다.
위치 정보는 최소화한다.
공공데이터 표준화는 김도성 기준을 따른다.
rideRequests 상태값은 심현석 기준을 따른다.
앱은 스키마를 임의로 바꾸지 않는다.
```
