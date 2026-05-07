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

