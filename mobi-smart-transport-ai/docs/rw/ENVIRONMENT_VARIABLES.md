# docs/rw/ENVIRONMENT_VARIABLES.md

> MOBI 프로젝트에서 사용하는 환경변수 설명 문서이다.  
> 실제 값은 `.env` 파일에 작성하고, `.env`는 절대 GitHub에 커밋하지 않는다.  
> 공개 저장소에는 `.env.example`만 포함한다.

---

## 1. 기본 원칙

```txt
- 실제 API key, Firebase private key, service account JSON은 GitHub에 올리지 않는다.
- .env 파일은 로컬에서만 사용한다.
- .env.example에는 예시 값 또는 빈 값만 둔다.
- 팀원이 새 환경변수를 추가하면 이 문서도 함께 최신화한다.
```

---

## V2 mock/live 전환 기준

V2에서는 각자 만든 mock-first 모듈을 앱-백엔드 중심으로 연결하므로, mock/live 여부를 섹션 결과에 반드시 기록한다.

| 변수 | Status | 기본 방향 | 담당 |
|---|---|---|---|
| `APP_ENV` | current | `development`, `test`, `production` 중 하나로 실행 환경 표시 | 공통 |
| `PUBLIC_DATA_USE_MOCK` | current | 기본은 `true`; live API 검증 섹션에서만 `false` 사용 | 김도성/현석 |
| `PUBLIC_DATA_BASE_URL` | current | live public data provider를 사용할 때 `https://apis.data.go.kr` 기준 | 김도성 |
| `FIREBASE_USE_MOCK` | V2 planned | Firebase Admin SDK 대신 mock Firebase client를 강제할 때 사용 | 현석 |
| `FCM_USE_MOCK` | V2 planned | 실제 FCM 전송 대신 mock message id 반환을 강제할 때 사용 | 현석 |
| `API_BASE_URL` | current dart-define | Flutter 앱이 호출할 FastAPI base URL | 윤현섭 |
| `USE_MOCK_DATA` | current dart-define | Flutter 앱 내부 mock data 사용 여부 | 윤현섭 |

주의:

```txt
- FIREBASE_USE_MOCK, FCM_USE_MOCK은 V2 환경변수 정리 섹션에서 .env.example 반영 여부까지 확정한다.
- 현재 문서 최신화 작업은 기능 코드나 환경파일 구현을 변경하지 않는다.
- 실행하지 않은 live 검증은 PASS로 기록하지 않는다.
```

---

## 2. 공통 환경변수

### APP_ENV

```txt
APP_ENV=development
```

설명:

```txt
현재 실행 환경을 나타낸다.
```

권장 값:

```txt
development
test
production
```

---

### LOG_LEVEL

```txt
LOG_LEVEL=debug
```

설명:

```txt
서버 또는 스크립트 로그 레벨.
```

권장 값:

```txt
debug
info
warning
error
```

---

## 3. Firebase 관련 환경변수

담당자: 심현석

### FIREBASE_PROJECT_ID

```txt
FIREBASE_PROJECT_ID=your-firebase-project-id
```

설명:

```txt
Firebase 프로젝트 ID.
```

---

### FIREBASE_DATABASE_URL

```txt
FIREBASE_DATABASE_URL=https://your-project-id-default-rtdb.firebaseio.com
```

설명:

```txt
Firebase Realtime Database URL.
```

---

### FIREBASE_SERVICE_ACCOUNT_PATH

```txt
FIREBASE_SERVICE_ACCOUNT_PATH=./secrets/firebase-service-account.json
```

설명:

```txt
Firebase Admin SDK에서 사용할 service account JSON 파일의 로컬 경로.
```

주의:

```txt
이 JSON 파일은 절대 GitHub에 커밋하지 않는다.
secrets/ 폴더는 .gitignore에 포함한다.
```

---

### FIREBASE_USE_MOCK

```txt
FIREBASE_USE_MOCK=true
```

설명:

```txt
V2 planned 변수. Firebase Admin SDK 대신 mock Firebase client를 사용할지 여부.
현석 Section 9에서 현재 Firebase mock 선택 로직과 맞춰 .env.example 반영 여부를 확정한다.
```

---

### FIREBASE_STORAGE_BUCKET

```txt
FIREBASE_STORAGE_BUCKET=your-project-id.appspot.com
```

설명:

```txt
향후 이미지, 오디오, 기타 리소스 저장이 필요한 경우 사용할 Firebase Storage bucket.
4월 MVP에서는 필수값이 아닐 수 있다.
```

---

## 4. FCM 관련 환경변수

담당자: 심현석

### FCM_ENABLED

```txt
FCM_ENABLED=false
```

설명:

```txt
FCM 푸시 알림 기능 사용 여부.
```

4월 개발 초기에는 `false`로 두고 skeleton/mock으로 개발할 수 있다.

---

### FCM_USE_MOCK

```txt
FCM_USE_MOCK=true
```

설명:

```txt
V2 planned 변수. 실제 FCM 전송 대신 mock FCM 응답을 사용할지 여부.
현석 Section 9에서 .env.example 반영 여부와 FCM_ENABLED와의 우선순위를 확정한다.
```

---

### FCM_TEST_USER_TOKEN

```txt
FCM_TEST_USER_TOKEN=
```

설명:

```txt
사용자 앱 테스트용 FCM 토큰.
실제 토큰은 공개 저장소에 올리지 않는다.
```

---

### FCM_TEST_DRIVER_TOKEN

```txt
FCM_TEST_DRIVER_TOKEN=
```

설명:

```txt
기사 앱 테스트용 FCM 토큰.
실제 토큰은 공개 저장소에 올리지 않는다.
```

---

## 5. 공공데이터 API 관련 환경변수

담당자: 김도성

### PUBLIC_DATA_API_KEY

```txt
PUBLIC_DATA_API_KEY=your-public-data-api-key
```

설명:

```txt
공공데이터포털 API 서비스키.
```

주의:

```txt
실제 서비스키는 GitHub에 올리지 않는다.
```

---

### PUBLIC_DATA_BASE_URL

```txt
PUBLIC_DATA_BASE_URL=https://apis.data.go.kr
```

설명:

```txt
공공데이터 API 기본 URL.
실제 사용할 API가 확정되면 김도성 에이전트가 최신화한다.
```

---

### PUBLIC_DATA_CITY_CODE

```txt
PUBLIC_DATA_CITY_CODE=
```

설명:

```txt
지역/도시 코드가 필요한 API에서 사용할 값.
충북/청주 등 실제 대상 지역이 확정되면 작성한다.
```

---

### PUBLIC_DATA_USE_MOCK

```txt
PUBLIC_DATA_USE_MOCK=true
```

설명:

```txt
공공데이터 API를 실제 호출하지 않고 mock JSON을 사용할지 여부.
```

4월 MVP에서는 mock 우선 개발을 허용한다.

---

## 6. 백엔드 API 관련 환경변수

담당자: 심현석

### BACKEND_HOST

```txt
BACKEND_HOST=127.0.0.1
```

설명:

```txt
FastAPI 서버 host.
```

---

### BACKEND_PORT

```txt
BACKEND_PORT=8000
```

설명:

```txt
FastAPI 서버 port.
```

---

### BACKEND_CORS_ORIGINS

```txt
BACKEND_CORS_ORIGINS=http://localhost:3000,http://localhost:5173
```

설명:

```txt
개발 중 허용할 CORS origin 목록.
Flutter 앱 테스트 방식에 따라 변경 가능.
```

---

## 7. Flutter 앱 관련 환경변수 또는 dart-define

담당자: 윤현섭

Flutter에서는 `.env` 대신 `--dart-define`을 사용할 수 있다.

### API_BASE_URL

```txt
API_BASE_URL=http://127.0.0.1:8000
```

Flutter 실행 예시:

```bash
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

설명:

```txt
사용자 앱/기사 앱이 호출할 백엔드 API 기본 URL.
```

---

### USE_MOCK_DATA

```txt
USE_MOCK_DATA=true
```

Flutter 실행 예시:

```bash
flutter run --dart-define=USE_MOCK_DATA=true
```

설명:

```txt
실제 백엔드 대신 mock 데이터를 사용할지 여부.
```

4월 MVP 초기에는 `true` 사용 가능.

---

## 8. 모바일 센서 관련 환경변수

담당자: 안준환

모바일 앱 센서 기능은 대부분 런타임 권한에 의존하므로 환경변수가 많지 않다.  
다만 테스트 기준값을 둘 경우 아래 값을 사용할 수 있다.

### DEFAULT_BEACON_TX_POWER

```txt
DEFAULT_BEACON_TX_POWER=-59
```

설명:

```txt
RSSI 거리 추정 공식에서 사용할 기준 TxPower 값.
실제 비콘 장비에 따라 조정한다.
```

---

### RSSI_SMOOTHING_WINDOW

```txt
RSSI_SMOOTHING_WINDOW=5
```

설명:

```txt
RSSI smoothing에 사용할 최근 샘플 개수.
```

---

## 9. AI 비전 관련 환경변수

담당자: 김도성

4월에는 실제 모델 학습/추론 코드나 Flutter/백엔드 실시간 통합을 구현하지 않는다. 아래 변수는 향후 확장과 mock 기반 준비를 위해 정의한다.

### AI_VISION_USE_MOCK

```txt
AI_VISION_USE_MOCK=true
```

설명:

```txt
AI 비전 결과를 실제 모델이 아니라 mock으로 사용할지 여부.
```

---

### AI_VISION_MODEL_PATH

```txt
AI_VISION_MODEL_PATH=./ai_vision/models/model.tflite
```

설명:

```txt
향후 모바일 경량 모델 파일 경로.
4월에는 실제 파일이 없어도 된다.
```

---

## 10. 보안상 절대 커밋 금지 항목

```txt
.env
*.env
serviceAccountKey.json
firebase-service-account.json
*.pem
*.key
*.p12
secrets/
.env.local
.env.production
```

이 항목들은 `.gitignore`에 포함되어야 한다.

---

## 11. .env.example 권장 형태

```env
APP_ENV=development
LOG_LEVEL=debug

FIREBASE_PROJECT_ID=
FIREBASE_DATABASE_URL=
FIREBASE_SERVICE_ACCOUNT_PATH=./secrets/firebase-service-account.json
FIREBASE_STORAGE_BUCKET=

FCM_ENABLED=false
FCM_TEST_USER_TOKEN=
FCM_TEST_DRIVER_TOKEN=

PUBLIC_DATA_API_KEY=
PUBLIC_DATA_BASE_URL=https://apis.data.go.kr
PUBLIC_DATA_CITY_CODE=
PUBLIC_DATA_USE_MOCK=true

BACKEND_HOST=127.0.0.1
BACKEND_PORT=8000
BACKEND_CORS_ORIGINS=http://localhost:3000,http://localhost:5173

API_BASE_URL=http://127.0.0.1:8000
USE_MOCK_DATA=true

DEFAULT_BEACON_TX_POWER=-59
RSSI_SMOOTHING_WINDOW=5

AI_VISION_USE_MOCK=true
AI_VISION_MODEL_PATH=./ai_vision/models/model.tflite
```

---

## 12. 환경변수 추가 절차

새 환경변수를 추가해야 할 경우:

```txt
1. 필요한 이유 확인
2. 담당 팀원 확인
3. .env.example에 예시 추가
4. docs/rw/ENVIRONMENT_VARIABLES.md에 설명 추가
5. 실제 값은 .env에만 작성
6. PR 본문에 추가 환경변수 명시
```

---

## 13. 최종 원칙

```txt
비밀값은 절대 커밋하지 않는다.
.env.example은 공유한다.
.env는 로컬에만 둔다.
환경변수를 추가하면 문서도 같이 고친다.
Firebase key와 공공데이터 key는 특히 조심한다.
```
