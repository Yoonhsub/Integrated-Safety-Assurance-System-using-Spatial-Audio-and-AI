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

