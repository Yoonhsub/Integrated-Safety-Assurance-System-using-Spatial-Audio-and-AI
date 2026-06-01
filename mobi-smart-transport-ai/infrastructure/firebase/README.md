# Firebase Infrastructure - 심현석 담당 영역

Firebase Realtime Database, FCM, 보안 규칙 초안 영역입니다.

## 4월 구현 범위

- RTDB 논리 스키마 확정
- users/drivers/busStops/geofences/busArrivals/rideRequests 경로 설계
- FCM token 저장 경로 정의
- 최소 개발용 rules 초안 작성

## 주의

공공데이터 API 직접 호출 구현은 하지 않습니다. `busArrivals`에는 김도성 public_data 서비스의 표준화 결과가 저장되거나 백엔드 게이트웨이를 통해 전달됩니다.

## V3 데모 세션 경로 (`v3GuidanceSessions`)

V3 음성 기반 버스 탑승 보조 데모를 위해 `v3GuidanceSessions/{sessionId}` 경로를 추가했습니다.

- `realtime_database.schema.json`에 논리 스키마를 정의했습니다.
- `database.rules.json`에는 인증 사용자 `.read`만 허용하고 클라이언트 `.write`는 막았습니다.

### 보안 규칙과 Admin SDK 관계 (중요)

- **백엔드(FastAPI)는 Firebase Admin SDK를 사용하므로 위 보안 규칙의 영향을 받지 않습니다.** Admin SDK는 서비스 계정 권한으로 동작하여 `.read`/`.write`가 `false`인 경로에도 읽기/쓰기가 가능합니다.
- 따라서 `POST /firebase/initialize`의 데모 seed와 `/v3GuidanceSessions` 세션 persistence는 규칙과 무관하게 백엔드에서 수행됩니다.
- 보안 규칙은 **Flutter 클라이언트 등 SDK가 아닌 직접 접근**을 제어하기 위한 것입니다. 데모에서 클라이언트는 RTDB에 직접 쓰지 않고 항상 백엔드 endpoint를 통해 초기화/갱신합니다.
- 기본값으로 루트 `.read`/`.write`는 `false`를 유지하여 운영 보안 규칙을 과도하게 느슨하게 열지 않았습니다.

### 서비스 계정이 없을 때

`backend/api/secrets/firebase-service-account.json`이 없으면 백엔드는 실제 RTDB 대신 in-memory mock store에 동일 구조로 seed/persist 하며, 보안 규칙은 적용되지 않습니다(로컬 데모 동작).
