# V3 API Contracts

Base URL: `http://127.0.0.1:8000` (local) / `http://10.0.2.2:8000` (Android emulator)

## Guidance Session

### POST /guidance/session
세션 생성 또는 반환

### GET /guidance/state?sessionId=
현재 세션 상태 반환

### POST /guidance/state/reset
IDLE로 리셋

### POST /guidance/start
안내 시작 (ROUTE_SELECTED 상태로 전이)

### POST /guidance/transition
상태 전이 (테스트/시연용)

### POST /guidance/boarding-confirm
탑승 확인 또는 실패 처리

## Bus V3

### POST /bus/route-recommend
목적지 기반 노선 추천

### GET /bus/arrivals?stopId=&routeNo=
버스 도착 정보 조회

## Agent

### POST /agent/converse
음성 발화 처리

## Geofence

### POST /geofence/check
위치 기반 지오펜스 판정

### POST /mock/geofence
시연용 mock 지오펜스 이벤트

## Beacon

### POST /mock/beacons
시연용 mock 비컨 데이터

### POST /mock/bus-event
시연용 버스 이벤트 (BUS_PASSED 등)
