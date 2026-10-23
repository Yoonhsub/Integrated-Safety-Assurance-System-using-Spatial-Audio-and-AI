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

Flutter 3.41.6 / Dart 3.11.4로 다음 검사를 완료했습니다.

- passenger_app: flutter analyze --no-pub → No issues found!, 전체 테스트 14개 통과.
- mobile_sensors: flutter analyze --no-pub → No issues found!, 전체 테스트 32개 통과.
- 아래 지정된 웹 릴리스 빌드 성공. 산출물은 소스 패키지에 포함하지 않았습니다.

```powershell
flutter build web --release --no-pub --base-href /app/ --dart-define=MOBI_API_BASE_URL=https://mobi.35.232.72.197.nip.io --dart-define=MOBI_WEB_DEMO_ORIGIN_ENABLED=true
```

Windows의 한글 소스 경로에서 기존 voice_aurora.frag 셰이더 컴파일러가
접근 위반으로 종료되어 앱 테스트와 웹 빌드는 동일 소스를 영문 임시 경로에 복사해
실행했습니다. 셰이더 소스는 수정하지 않았습니다. 앱 pubspec.lock은 해당 SDK가 요구하는
테스트/Material 관련 의존성 5개를 갱신했습니다.
기존 flutter_tts의 WebAssembly 사전 검사와 CupertinoIcons 폰트 경고가 남아 있으며,
이번 일반 웹 빌드 성공은 WebAssembly 빌드 성공을 뜻하지 않습니다.
Android 실기기, 실제 BLE 비콘, 이어폰 및 현장 통합 검증은 아직 하지 않았습니다.

이번 실행 결과: Python 전체 테스트 273 passed, 구조 검사 PASS,
Backend compileall 통과, git diff --check 통과. 실제 로컬 uvicorn HTTP에서
기존 health/session/ingest/latest와 새 observations 조회, 실제 시간 만료,
목표 변경 시 캐시 초기화를 확인했습니다. 실제 BLE 하드웨어 검증은 포함하지 않습니다.

기존 main의 FINAL_FILE_LIST에는 실제 파일명과 맞지 않는 항목이 있어 구조 검사가
원본에서도 실패했습니다. 실제 패키지 파일 목록으로 갱신했으며 이 파일의 큰 diff는
애플리케이션 코드 변경과 분리해 검토해야 합니다.

## 2026-10-23 안준환 담당 조건 재검수

- 기록자: 안준환의 에이전트 / 브랜치: ajh_2semester.
- 대상: origin/main 6cce5b3 대비 기존 변경 17개 파일. 이번 재검수에서 실행 코드 변경 없음.
- 기준: 안준환 전용 필독사항, 공통 프롬프트, module_ownership.json, CODEOWNERS, SRS FR-020~024/NFR-007~008, V2/V3 계획, 기존 AJH #36 보고서, sensor adapter/lifecycle/ingest bridge 가이드.
- 전체 md/txt를 모두 정독했다고 주장하지 않음. 전체 문서 경로 목록을 만들고 안준환 관련 조건과 공통 필수 규칙을 우선 검토함.

### 적용 시점과 소유권

4월 헤드트래킹 제외를 2학기 금지로 확대하지 않는다. V2 담당은 mobile_sensors이며 V3 공통 진행사항에는 안준환의 앱 공간음향/mock 음성 PR #49 이력이 있다. 이 이력만으로 이번 관찰 UI/API/세션 저장소 변경의 합의가 있었다고 간주하지 않는다. 현재 대화의 개발 요청은 있었지만 이번 경계 변경에 대한 팀원 합의 근거는 로컬 문서에서 확인하지 못했다.

| 검토 파일 | 공식 소유/검토 대상 | 판정 |
|---|---|---|
| `apps/passenger_app/lib/src/pages/v3_guidance_page.dart` | 윤현섭 | 이번 BLE 관찰 UI/client/테스트 및 SDK lock 변경 협의 확인 필요 |
| `apps/passenger_app/lib/src/services/v3_agent_api_client.dart` | 윤현섭 | 이번 BLE 관찰 UI/client/테스트 및 SDK lock 변경 협의 확인 필요 |
| `apps/passenger_app/lib/src/widgets/beacon_observation_panel.dart` | 윤현섭 | 이번 BLE 관찰 UI/client/테스트 및 SDK lock 변경 협의 확인 필요 |
| `apps/passenger_app/pubspec.lock` | 윤현섭 | 이번 BLE 관찰 UI/client/테스트 및 SDK lock 변경 협의 확인 필요 |
| `apps/passenger_app/test/beacon_observation_test.dart` | 윤현섭 | 이번 BLE 관찰 UI/client/테스트 및 SDK lock 변경 협의 확인 필요 |
| `backend/api/app/api/routes/v3_beacon_ingest.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/app/schemas/beacon_observation.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/app/schemas/v3.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/app/services/beacon_observation_access.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/app/services/beacon_observation_store.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/app/services/beacon_registry.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/app/services/v3_guidance_store.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/tests/test_beacon_observations.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `backend/api/tests/test_beacon_registry.py` | 심현석 | 새 관찰 계약 및 기존 ingest/session 동작 변경 협의 확인 필요 |
| `config/beacon_registry.example.json` | 공통 | 설정/문서 변경으로 공통 검토 필요; 센서 패키지 소유 경로가 아님 |
| `docs/developer_a/MAIN_BASE_INTEGRATION.md` | 공통 | 설정/문서 변경으로 공통 검토 필요; 센서 패키지 소유 경로가 아님 |
| `docs/read/FINAL_FILE_LIST.txt` | 공통 | 설정/문서 변경으로 공통 검토 필요; 센서 패키지 소유 경로가 아님 |

### 발견한 제한과 계약 차이

1. 이번 17개 변경에는 packages/mobile_sensors 소스 변경이 없다. BLE 스캔/거리 계산/방향 센서 자체를 이번에 새로 완성한 것으로 보고하지 않는다.
2. /api/v3/beacon/observations와 신규 응답 schema는 기존 bridge의 ingest/latest 흐름에 추가된 별도 계약이다. shared_contracts에 정식 등록하거나 팀 계약으로 확정한 상태가 아니다.
3. macAddress 수용은 기존 BeaconIngestBridge 형식과 맞지만 기존 v3_beacon_service의 target/wrong 판정은 변경하지 않았다. MAC별 실제 차량 판별 완료를 뜻하지 않는다.
4. timestamp UTC offset 필수 검증은 기존 timezone 없는 요청을 422로 바꾼다. 기존 Bridge는 DateTime.toIso8601String()을 사용하므로 local DateTime 샘플 호환성도 별도 확인해야 한다. 기존 테스트 통과만으로 모든 이전 호출자 호환성을 보증하지 않는다.
5. session create/reset/목표 변경 시 기존 legacy 비콘 캐시도 비운다. 이 동작은 새 관찰 플래그가 꺼져 있어도 적용되므로 단순 독립 조회 기능 추가로만 설명할 수 없다.
6. 새 관찰 저장/조회는 실제 loopback 연결+BEACON_OBSERVATIONS_LOCAL=1 한정이다. 실제 휴대폰에서 PC/LAN 서버로 보내는 요청은 새 관찰에 기록되지 않으며 외부 조회는 403이다. 기존 ingest 응답과 새 관찰 기능을 구분해야 한다. 접근 제한을 임의로 완화하지 않는다.
7. config의 비콘/차량 ID는 예시 placeholder이다. 실측 A/B 비콘 등록, Android 권한/스캔/서버 왕복, 방향 센서 실측, 이어폰/현장 테스트는 완료로 판정하지 않는다.

### 검증 증거와 현재 판정

- 이전 실행: Python 273 passed, compileall/로컬 HTTP 확인. 이번에는 Python 소스 변경 없음.
- Flutter 3.41.6: 앱 analyze PASS/14 tests PASS, mobile_sensors analyze PASS/32 tests PASS, 지정 옵션 release web build 성공. 앱 테스트와 빌드는 한글 경로 셰이더 도구 충돌로 동일 소스의 영문 임시 경로에서 실행.
- 기존 flutter_tts Wasm 사전 검사 및 아이콘 폰트 경고 잔존. 실제 BLE 및 오디오 하드웨어는 NOT_RUN.
- 미해결 협업 이슈: CONFLICT-20261023-안준환-002. 테스트 통과와 담당 범위/계약 합의는 별개이다. 문서 조건 전체 충족 또는 개발자 A 전체 완료로 판정하지 않는다.
- 다음 순서: 심현석과 ingest 시간대/MAC/세션 캐시/관찰 접근 및 응답 계약 확인, 윤현섭과 관찰 UI/client/의존성 연결 확인, 합의 범위 내 최소 패치 후 실제 Android A/B BLE 검증.
- 기존 작업 파일은 보존한다. 이번 요청은 재검수/기록 승인으로 해석하며, 미해결 경계 변경의 강행 승인으로 기록하지 않는다. 커밋/푸시/PR/VM 접근/배포 없음.

## 2026-10-23 BLE bridge UTC 전송 보완

- 기록자: 안준환의 에이전트 / ajh_2semester.
- 원인: 로컬 DateTime.toIso8601String()은 시간대 표시가 없어서 현재 backend ingest의 UTC offset 필수 검증에 거부될 수 있음. 실제 scanner에서 생성한 로컬 측정 시각에도 해당할 수 있음.
- 수정: packages/mobile_sensors/lib/src/beacon_ingest_bridge.dart의 JSON timestamp를 toUtc().toIso8601String()으로 직렬화. 측정 시점과 내부 timestamp 객체는 유지하며 필드명을 변경하지 않음.
- 회귀 검증: 로컬 timestamp 테스트가 수정 전 Z 누락으로 FAIL함을 확인. 수정 후 로컬 시각의 동일 순간 보존, 기존 UTC 형식 보존, MockClient가 받은 A/B 전송 본문을 검증함. mock target/wrong 응답은 실제 서버 차량 판정 검증이 아님.
- 이번 실행: 센서 패키지 flutter test 33 passed, flutter analyze No issues found!, backend 관찰/등록표 관련 회귀 테스트 28 passed (기존 AnyIO deprecation 경고 1개).
- 이번 변경에서 앱/백엔드 실행 코드 및 접근 제한은 변경하지 않음. 과거 앱/web/Python 전체 결과는 이전 실행 이력이며 이번에 재실행한 것으로 보고하지 않음.
- CONFLICT-20261023-안준환-002 중 센서 bridge의 timezone 전송 문제만 보완. 다른 이전 호출자의 호환성, legacy 캐시 초기화, 앱/API 계약 합의, 실기기 관찰 경로는 미해결 상태 유지.
- 하드웨어 현황 정정: 사용자가 비콘과 골전도 이어폰을 보유한다고 확인함. 과거 '하드웨어 환경 없음' 표현을 현재 장비 미보유로 해석하지 않음. 실제 테스트는 아직 NOT_RUN이며 휴대폰 OS 및 A/B 식별자를 확인 중.
- 다음: 휴대폰 OS/비콘 ID 확인 후 실제 BLE 수신, 서버 ingest, 이어폰 cue 출력을 순서대로 검증. 비콘 구분과 이어폰 출력은 별도 결과로 기록하며 실측 전 완료로 표시하지 않음.
- 커밋/푸시 미수행. 한국어 변경 설명을 사용자에게 미리 검수받은 뒤 업로드.

## 2026-10-23 하드웨어 확인 결과 및 브랜치 최신화 범위

- 기록자: 안준환의 에이전트 / ajh_2semester. 앞선 NOT_RUN 표기는 당시 기록으로 보존하며 현재 결과는 이 항목을 따른다.
- 대상 장비: Android SM-S942N, E2 A C3:00:00:5C:B9:47 / B C3:00:00:5C:B9:48, WIT Motion WT901BLE68 F1:35:40:62:CD:43, 사용자 보유 골전도 이어폰.
- 검증 위치: 본 저장소 밖 바탕화면 MOBI_BLE_TEMP 임시 Android 앱 v1.2.0. 기존 센서 모델/거리 계산 패키지를 참조하되, 연속 스캐너/WT901 어댑터/오디오 UI 및 Android PCM 출력은 임시 앱에만 작성했다.
- 사용자 확인 완료: A/B 비콘 연속 수신, 개별 식별, 이동에 따른 RSSI 변화, 센서 각도 수신, 비콘/센서 동시 수신, 스캔 종료 후 센서 연결 유지, 골전도 소리 테스트. 사용자가 하드웨어 테스트를 여기서 마무리한다고 명시했다.
- 구현된 임시 앱 테스트음: 수동 기준각에 대한 Z 상대 회전으로 좌우 채널 음량 조절, 선택한 A/B 비콘의 보정 RSSI로 0.22~1.40초 간격 조절. 사용자 소리 테스트 완료 보고를 기록하며 정량 오차·지연·모든 임계값을 계측했다고 주장하지 않는다.
- 임시 앱 코드 검증: Flutter analyze No issues found!, 테스트 13개 PASS, debug APK 빌드/설치 확인. 기존 프로젝트 센서 패키지는 앞선 33개 테스트/analyze PASS, backend 관련 28개 테스트 PASS이며 이번 문서 최신화에서 재실행한 것으로 기록하지 않는다.
- 기존 스캐너의 continuousUpdates 미지정과 임시 화면 재생성에 따른 센서 연결 종료를 발견했다. 해결 코드는 임시 앱에만 존재한다. 본 프로젝트 FlutterBlueBeaconScanner의 연속 수신 문제가 이미 해결된 것으로 표시하지 않는다.
- 이번 업로드 대상: 본 프로젝트의 BeaconIngestPayload UTC 직렬화 수정, 회귀 테스트, 기존 안준환 보고서/가이드/관련 협업 기록. 임시 앱 소스·APK·빌드 도구·새 Android 앱 폴더는 업로드 대상에서 제외한다.
- 미반영 기능: 본 프로젝트의 연속 BLE 수신 보완, WT901 연결/프로토콜 해석, 기준각 및 방향음/간격 조절, Android 실행/권한 환경. 해당 기능 통합은 별도 작업이다.
- 미검증 범위: 본 프로젝트 앱의 Android E2E, 실제 하드웨어→backend ingest/observations 왕복, 실제 차량 식별·정류장 현장, HRTF/앞뒤 음향 구분, 모든 끊김/복구 시나리오의 실측. 추가 끊김 테스트는 사용자 요청에 따라 더 진행하지 않았으므로 완료로 처리하지 않는다.
- CONFLICT-20261023-안준환-002: 하드웨어 미보유/전혀 미검증 상태는 정정되었지만 앱·backend 계약 합의, legacy 캐시 초기화, 다른 호출자의 timestamp 호환성, LAN 관찰 경로는 여전히 미해결이다. 장비 확인을 근거로 협업 이슈를 해결 처리하지 않는다.
- 푸시 절차: 한국어 커밋/변경 설명을 사용자에게 제시하고 검수 후 업로드한다. 본 항목 작성 시 커밋/푸시 미수행, PR/병합/배포 없음.


### 2026-10-23 임시 앱 저장소 포함 — 최신 범위 변경

사용자 안준환의 요청에 따라 저장소 루트에 `temporary_test_app/`을 추가한다. 이전의 "임시 앱 미포함" 기록은 당시 범위이며, 현재 업로드 검수 범위에는 독립 테스트 앱 소스와 한국어 `실행방법.md`를 포함한다.
비콘 2개/WT901 동시 수신과 골전도 방향음·RSSI 간격 조절의 별도 테스트 앱이다. 기존 바탕화면 개인 앱은 보존한다. Passenger 앱/서버 통합을 의미하지 않는다.
상대 경로로 기존 mobile_sensors를 참조하며 APK/build/로컬 SDK 경로/키는 제외한다. 커밋·푸시는 변경 설명의 사용자 검수 후 진행한다.
기존 CONFLICT-20261023-안준환-002는 별도 협업 검토가 필요하며 이 추가로 해결 처리하지 않는다.
