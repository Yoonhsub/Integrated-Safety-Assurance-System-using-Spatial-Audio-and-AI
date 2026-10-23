# 개발자 A: main 기준 로컬 BLE 관찰

## 기준

- 기준: origin/main `6cce5b329dc3dc581343e08d1bee13a00da00fe6`
- 로컬 작업 브랜치: `ajh_2semester`
- GitHub push, PR, merge, 배포는 수행하지 않았습니다.
- 처음 만든 바탕화면 MOBI_SOUND_개발자A 폴더의 소스를 작업 기준으로 사용합니다.
- 이전 팀원 기준 통합본은 작업용 백업에 보관했습니다.

팀원 브랜치 전체를 main 위에 덮어쓰지 않았습니다. main에 없는 app.security,
FirebaseAuthSession, Vision Binding/generation, 계정 소유권 검사, Vision 음성,
head tracking 코드를 추가하거나 의존하지 않습니다. 기존 버스/오디오/Vision
처리는 유지하고 A 담당 비콘 관찰 기능을 독립적으로 연결했습니다.

## 추가 기능

- 같은 세션의 여러 기기/비콘 측정값을 개별 보관하는 관찰 캐시.
- 서버 JSON 설정표에 등록된 비콘-차량 라벨 표시. 요청 busId를 라벨의 근거로 사용하지 않음.
- 표준화된 관찰 응답: RSSI, 거리 추정, source, observedAt, proximity, validForSeconds.
- false로 고정된 guidanceEligible/vehicleIdentityVerified/shouldSpeak/shouldPlaySpatialCue.
- 타임스탬프와 서버 단조 시계에 따른 만료. 중복/역순/미래/오래된 입력 배제.
- 활성 후보 128개, 중복 검사 키 512개 상한. 만료 후 같은 샘플을 재전송해도 부활시키지 않음.
- 목표 차량/노선/정류장/여정 구간 변경, 세션 초기화/재생성/승차 완료 시 캐시 정리.
- 실 API 화면에 선택적으로 표시하는 BLE 관찰 패널. 요청 중복 방지, 화면 scope 변경 시 늦은 응답 무시,
  요청 시간과 로컬 경과 시간을 반영한 만료 표시. 오디오를 호출하지 않음.
- 기존 모바일 bridge의 macAddress 필드 수용과 시간대 없는 timestamp 검증.

## main과의 경계

main에는 팀원 브랜치의 계정 인증/소유권 기능이 없습니다. 이를 제거하거나 인증이
있는 것처럼 표현하지 않고, 새 관찰 조회와 수집은 기본 비활성인 로컬 데모로 제한했습니다.
새 관찰 API는 계정별 인증이나 승객별 접근 제어의 대체물이 아닙니다.

- Backend `BEACON_OBSERVATIONS_LOCAL=1`일 때만 새 관찰 정보를 보관/조회합니다.
- 조회는 loopback(127.0.0.1/::1) 연결만 허용하며, 단순 전달 헤더로 허용하지 않습니다.
- 플래그 미지정 시 GET /api/v3/beacon/observations는 404, 외부 연결은 403입니다.
- 존재하지 않는 세션은 조회로 생성하지 않고 404, 승차 완료 세션은 409입니다.
- 기존 /ingest, /latest, /reset과 main의 기존 안내 판정은 유지합니다. 기존 endpoint를
  새로 인증된 것으로 바꾸거나 기존 차량 판별의 신뢰성을 보증하지 않습니다.
- 새 관찰값은 안내 상태·승차 허용·목표 차량 확인·음성 출력으로 승격하지 않습니다.
- 공개 서버에서 이 로컬 옵션을 켜거나 계정 정보 조회 기능으로 사용하지 않습니다.
- 사용자별 서비스 연결은 팀의 인증 기반 코드가 main에 들어온 뒤 별도 통합해야 합니다.

## 로컬 실행

mobi-smart-transport-ai 폴더에서:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r backend/api/requirements.txt pytest
$env:FIREBASE_USE_MOCK='true'
$env:BEACON_OBSERVATIONS_LOCAL='1'
.\.venv\Scripts\python.exe -m uvicorn app.main:app --app-dir backend/api --host 127.0.0.1 --port 8000
```

먼저 기존 POST /guidance/session으로 세션을 만들고, 같은 sessionId로 로컬
POST /api/v3/beacon/ingest를 호출합니다. 그 후 다음 조회로 관찰 정보를 확인합니다.

```text
GET /api/v3/beacon/observations?sessionId=<만든 세션 ID>
```

비콘 설정표는 config/beacon_registry.example.json을 실제 ID로 교체한 별도 JSON에 저장하고
Backend 시작 전에 BEACON_REGISTRY_PATH로 지정합니다. 상대 경로는 프로젝트 루트 기준이며
파일 변경 후 재시작해야 합니다. 설정표 등록은 전파 송신자 인증이나 실제 차량 검증이 아닙니다.

## 앱 실행

main의 V3AgentApiClient를 사용하며 계정 SDK 의존성을 추가하지 않았습니다.
기존 화면에서 사용하는 sessionId/updatedAt을 scope로 사용합니다. 패널은 기본 비활성입니다.

```powershell
cd apps/passenger_app
flutter pub get
flutter run -d chrome --web-port 8080 --dart-define=MOBI_API_BASE_URL=http://127.0.0.1:8000 --dart-define=MOBI_BEACON_OBSERVATIONS_ENABLED=true
```

기존 API가 존재하고 Backend의 CORS 설정에 로컬 프론트 주소가 허용되어 있어야 합니다.

## 검사

```powershell
python -m pytest -q -p no:cacheprovider
```

Flutter SDK가 있는 환경에서 별도로 flutter analyze, 지정된 release 웹 빌드,
flutter test test/beacon_observation_test.dart를 실행해야 합니다.
이 작업 환경에는 Flutter SDK가 없어 Flutter 검사와 Android 실기기 검증을 실행하지 못했습니다.
따라서 이 로컬 수정본은 PR 전 필수 검수를 모두 완료한 상태가 아닙니다.

이번 실행 결과: Python 전체 테스트 273 passed, 구조 검사 PASS,
Backend compileall 통과, git diff --check 통과. 실제 로컬 uvicorn HTTP에서
기존 health/session/ingest/latest와 새 observations 조회, 실제 시간 만료,
목표 변경 시 캐시 초기화를 확인했습니다. 실제 BLE 하드웨어 검증은 포함하지 않습니다.

기존 main의 FINAL_FILE_LIST에는 실제 파일명과 맞지 않는 항목이 있어 구조 검사가
원본에서도 실패했습니다. 실제 패키지 파일 목록으로 갱신했으며 이 파일의 큰 diff는
애플리케이션 코드 변경과 분리해 검토해야 합니다.
