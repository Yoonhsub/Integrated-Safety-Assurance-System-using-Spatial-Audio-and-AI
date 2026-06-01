# V3 Demo Script

## 전제

- FastAPI 서버가 `http://127.0.0.1:8000`에서 실행 중이어야 한다.
- Gemini API key는 없어도 된다.
- 공공버스 API key는 없어도 된다.
- 실제 버스 위치/혼잡도/live 검증을 지어내지 않는다.
- V3 demo stop은 mock/cache fallback으로 시연한다.

## 실행 명령

```bash
cd backend/api
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

다른 터미널:

```bash
python scripts/smoke_v3_guidance.py
```

다른 백엔드 주소를 쓸 때:

```bash
V3_API_BASE_URL=http://127.0.0.1:8000 python scripts/smoke_v3_guidance.py
```

## 수동 시연 흐름

1. `GET /health`
   - 기대: `status=ok`
2. `POST /guidance/session`
   - 요청: `sessionId=demo-session`, `wakeWord=자비스`
   - 기대: `state=IDLE`
3. `POST /agent/converse`
   - 발화: “자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?”
   - 기대: `intent=FIND_ROUTE`, `state=ROUTE_RECOMMENDED`
4. `GET /bus/arrivals?stopId=mock-stop-001&routeNo=502`
   - 기대: 첫 번째 도착 버스 `BUS_2`, `arrivalMinutes=6`, `congestion=null`
5. `POST /agent/converse`
   - 발화: “자비스, 그 버스 언제 와?”
   - 기대: `intent=QUERY_ARRIVAL`
6. `POST /agent/converse`
   - 발화: “응, 6분 뒤 오는 걸로 안내해줘.”
   - 기대: `intent=SELECT_ARRIVAL`, `state=WAITING_FOR_BUS`, `targetBusId=BUS_2`
7. `POST /mock/geofence`
   - event: `ARRIVED_AT_STOP`
   - 기대: `geofenceArmed=true`
8. `POST /mock/geofence`
   - event: `LEFT_WAITING_AREA`
   - 기대: `cue.type=GEOFENCE_WARNING`, `cue.ttsMode=SAFETY_LOCAL`
9. `POST /mock/beacons`
   - `BUS_1=511 near`, `BUS_2=502 mid`
   - 기대: `decision=WRONG_BUS_NEAR`
10. `POST /agent/converse`
    - 발화: “자비스, 지금 앞에 온 버스 타도 돼?”
    - 기대: 부정 응답, `cue.type=WRONG_BUS_NEAR`
11. `POST /mock/beacons`
    - `BUS_2=502 near`
    - 기대: `decision=TARGET_BUS_NEAR`, 상태는 `BOARDING_CONFIRMATION`
12. `POST /mock/bus-event`
    - event: `BUS_PASSED`
    - 기대: `state=MISSED_BUS`
13. `POST /agent/converse`
    - 발화: “자비스, 나 못 탔어.”
    - 기대: `intent=REPORT_MISSED_BUS`, `state=WAITING_FOR_BUS`, 다음 target bus 안내
14. `GET /guidance/state`
    - 기대: `targetBusId=BUS_502_NEXT`

## Flutter 시연

```bash
cd apps/passenger_app
flutter run --dart-define MOBI_API_BASE_URL=http://127.0.0.1:8000
```

Android emulator:

```bash
flutter run --dart-define MOBI_API_BASE_URL=http://10.0.2.2:8000
```

V3 화면은 홈 화면의 “V3 버스 탑승 보조 열기” 버튼 또는 `/v3-guidance` route로 접근한다.
