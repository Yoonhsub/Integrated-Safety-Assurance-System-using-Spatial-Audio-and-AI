# V3 API Contracts

기본 base URL:

```txt
http://127.0.0.1:8000
```

Android emulator에서 Flutter 앱이 로컬 백엔드에 붙을 때:

```txt
http://10.0.2.2:8000
```

## 공통 cue 계약

```json
{
  "type": "NONE | TARGET_BUS_FAR | TARGET_BUS_MID | TARGET_BUS_NEAR | WRONG_BUS_NEAR | GEOFENCE_WARNING | DANGER",
  "ttsMode": "NONE | LOCAL_TTS | SAFETY_LOCAL | GEMINI_OPTIONAL",
  "shouldVibrate": false,
  "shouldBeep": false,
  "message": null
}
```

안전 관련 cue는 Gemini에만 의존하지 않는다. `SAFETY_LOCAL`은 Flutter가 로컬 TTS·진동·비프를 우선 실행해야 한다.

## Health

```txt
GET /health
```

응답 예:

```json
{
  "status": "ok",
  "service": "mobi-backend-api",
  "environment": "development",
  "firebaseMode": "mock"
}
```

## Guidance

### Create session

```txt
POST /guidance/session
```

요청:

```json
{
  "sessionId": "demo-session",
  "wakeWord": "자비스"
}
```

응답은 `GuidanceSessionState`다.

### Get state

```txt
GET /guidance/state?sessionId=demo-session
```

주요 필드:

```json
{
  "sessionId": "demo-session",
  "state": "WAITING_FOR_BUS",
  "wakeWord": "자비스",
  "selectedDestination": "사창사거리",
  "selectedRouteNo": "502",
  "selectedRouteId": "mock-route-502",
  "selectedStopId": "mock-stop-001",
  "selectedStopName": "사창사거리 정류장",
  "targetBusId": "BUS_2",
  "geofenceArmed": true,
  "lastDecision": "WRONG_BUS_NEAR",
  "nearestBeacon": {},
  "targetBus": {},
  "updatedAt": "2026-05-30T00:00:00Z"
}
```

### Reset

```txt
POST /guidance/reset
```

요청:

```json
{
  "sessionId": "demo-session",
  "event": "RESET",
  "payload": {}
}
```

### Event transition

```txt
POST /guidance/event
```

주요 event:

```txt
ROUTE_RECOMMENDED
ROUTE_SELECTED
NAVIGATING_TO_STOP
ARRIVED_AT_STOP
WAITING_FOR_BUS
BOARDING_CONFIRMATION
BOARDED
MISSED_BUS
REPLAN_NEXT_BUS
```

`IDLE -> BOARDED` 같은 잘못된 직접 전이는 `409 INVALID_GUIDANCE_TRANSITION`으로 거부한다.

## Agent

```txt
POST /agent/converse
```

요청:

```json
{
  "sessionId": "demo-session",
  "wakeWord": "자비스",
  "utterance": "자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?"
}
```

응답 주요 필드:

```json
{
  "sessionId": "demo-session",
  "intent": "FIND_ROUTE",
  "state": "ROUTE_RECOMMENDED",
  "message": "사창사거리 방향은 사창사거리 정류장에서 502번을 타면 돼.",
  "ttsMode": "LOCAL_TTS",
  "cue": {},
  "usedGemini": false,
  "fallbackSource": "MOCK"
}
```

현재 rule fallback intent:

```txt
WAKE_ONLY
FIND_ROUTE
QUERY_ARRIVAL
SELECT_ARRIVAL
ASK_CAN_BOARD_CURRENT_BUS
REPORT_MISSED_BUS
CORRECT_DESTINATION
CHANGE_DESTINATION
UNKNOWN
```

Gemini API key가 없어도 동작한다. 실제 안전 판단/도착 시간 추측은 Gemini가 하지 않고 백엔드 rule과 bus arrival 응답에 따른다.

### TTS

```txt
POST /agent/tts
```

응답은 `audio/wav`이며 기본 Gemini TTS voice는 `Sulafat`이다.

## Bus

### Route recommend

```txt
GET /bus/route-recommend?destination=사창사거리&originLat=36.6281&originLng=127.4562
```

좌표를 함께 넘기면 Pro 모델이 Google Maps grounding과 검증된 데이터만 사용해 경로를
요약한다. 앱은 요청 중 `생각 중...` 오버레이를 표시하고 다음 문장을 즉시 읽는다.

```txt
요청하신 내용을 응답하기 위해 경로를 계산 중입니다. 잠시만 기다려 주세요.
```

승인된 청주시 정류소 카탈로그가 활성화되어 있으면 응답에 `stopEvidence`가 포함된다.
`stopEvidence.source=PUBLIC_API`는 실제 정류소명·서비스ID·좌표의 증빙이며, 도착 예정
시간의 출처를 의미하지 않는다. 도착정보는 `evidence.source`를 별도로 확인한다.

지원 destination/alias:

```txt
사창사거리, 사창 사거리, 사직사거리
충북대병원, 충북대학교병원, 충북대학교 병원, 충대병원
청주고속버스터미널, 청주 고속버스터미널, 청주터미널, 고속버스터미널, 터미널
```

unknown destination은 `404 UNKNOWN_DESTINATION`을 반환한다.

### Arrivals

```txt
GET /bus/arrivals?stopId=mock-stop-001&routeNo=502
```

mock 응답 예:

```json
{
  "stopId": "mock-stop-001",
  "routeNo": "502",
  "arrivals": [
    {
      "busId": "BUS_2",
      "routeNo": "502",
      "routeId": "mock-route-502",
      "stopId": "mock-stop-001",
      "arrivalMinutes": 6,
      "remainingStops": 2,
      "lowFloor": true,
      "congestion": null
    },
    {
      "busId": "BUS_502_NEXT",
      "routeNo": "502",
      "routeId": "mock-route-502",
      "stopId": "mock-stop-001",
      "arrivalMinutes": 13,
      "remainingStops": 6,
      "lowFloor": true,
      "congestion": null
    }
  ],
  "fallbackSource": "MOCK"
}
```

`fallbackSource` 값:

```txt
PUBLIC_API
CACHE
MOCK
ERROR
```

공공버스 API key가 없거나 live provider가 준비되지 않은 경우에도 V3 demo stop은 mock fallback으로 죽지 않는다. 혼잡도 정보는 실제/cache normalized source에 있을 때만 전달하고, V3 mock에서는 임의 생성하지 않는다.

## Mock Geofence

```txt
POST /mock/geofence
```

요청:

```json
{
  "sessionId": "demo-session",
  "event": "ARRIVED_AT_STOP"
}
```

지원 event:

```txt
ARRIVED_AT_STOP
LEFT_WAITING_AREA
DANGER_ZONE
RETURNED_TO_STOP
```

`LEFT_WAITING_AREA`는 `geofenceArmed=true` 이후에만 `GEOFENCE_WARNING`을 반환한다.

## Mock Beacons

```txt
POST /mock/beacons
```

요청:

```json
{
  "sessionId": "demo-session",
  "targetBusId": "BUS_2",
  "targetRouteNo": "502",
  "beacons": [
    {"busId": "BUS_1", "routeNo": "511", "rssi": -50, "distanceMeters": 1.5},
    {"busId": "BUS_2", "routeNo": "502", "rssi": -70, "distanceMeters": 7.0}
  ]
}
```

결과 decision:

```txt
NO_BEACON
WRONG_BUS_NEAR
TARGET_BUS_FAR
TARGET_BUS_MID
TARGET_BUS_NEAR
```

`targetBusId` 직접 매칭을 우선하고, 없으면 `routeNo` fallback을 사용한다. 가까운 다른 버스가 있으면 `WRONG_BUS_NEAR`로 안전 경고한다.

## Last Beacon Decision

```txt
GET /beacon/decision?sessionId=demo-session
```

마지막 `lastDecision`, `nearestBeacon`, `targetBus`를 반환한다.

## Mock Bus Event

```txt
POST /mock/bus-event
```

요청:

```json
{
  "sessionId": "demo-session",
  "event": "BUS_PASSED"
}
```

`BUS_PASSED`는 세션을 `MISSED_BUS`로 바꾼다. 이후 `/agent/converse`에 “나 못 탔어”를 보내면 다음 target bus로 재안내한다.
