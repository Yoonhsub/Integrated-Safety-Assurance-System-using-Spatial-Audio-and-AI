# V2 통합 MVP 고도화 12섹션 계획

## 0. V2 목표

V2의 목표는 각 팀원이 4~5월에 만든 mock-first 모듈을 실제 앱-백엔드 중심의 통합 가능한 구조로 연결하는 것이다.

이번 문서는 발표 대비 문서가 아니라 개발 진행 문서다. 각 팀원은 이 문서에서 자기 이름을 찾고, 자신의 V2 12섹션 목표, 의존성, 수행 기준, 테스트 기준을 확인한다.

## 1. 공통 진행 원칙

- 총 12섹션으로 진행한다.
- 홀수 섹션은 구현 중심이다.
- 짝수 섹션은 검증, 패치, 문서화 중심이다.
- 팀 전체가 같은 섹션 번호 흐름을 공유한다.
- 각 팀원은 자기 담당 영역만 수정한다.
- 실제 실행하지 않은 테스트는 PASS로 기록하지 않는다.
- 섹션 완료 시 mock/live 여부와 다음 섹션 의존성을 반드시 남긴다.

## 2. 전체 섹션 흐름

| Section | 공통 단계 | 성격 |
|---|---|---|
| 1~2 | 계약/API/환경 정리 | 구현 후 검증 |
| 3~4 | 버스 도착정보 통합 | 구현 후 검증 |
| 5~6 | 승차 지원 요청 통합 | 구현 후 검증 |
| 7~8 | 센서/AI 안전 이벤트 연결 | 구현 후 검증 |
| 9~10 | 예외처리, mock-live 경계, 안정성 | 구현 후 검증 |
| 11~12 | 전체 회귀검증, 문서 정리, 파일 목록 정합성 | 구현/정리 후 최종 검증 |

## 3. 팀원별 담당 영역

| 팀원 | V2 역할 | 주요 경로 |
|---|---|---|
| 현석 | Backend / Integration Backbone | `backend/api`, `infrastructure/firebase`, backend 관련 문서 |
| 김도성 | Public Data / AI Vision | `services/public_data`, `ai_vision`, public_data/AI vision 문서 |
| 안준환 | Sensor / BLE / Audio Cue | `packages/mobile_sensors`, sensor/audio cue 문서 |
| 윤현섭 | Flutter Passenger / Driver App | `apps/passenger_app`, `apps/driver_app`, 앱 README/보고서 |

## 4. 현석 - Backend / Integration Backbone

| Section | Goal | 작업 내용 | 완료 기준 |
|---|---|---|---|
| 1 | Backend API 계약 정리 | `/health`, `/bus-info/stops/{stopId}/arrivals`, `/ride-requests`, `/ride-requests/{id}`, `/driver/ride-requests`, `/driver/ride-requests/{id}/status`의 request/response schema와 error format 정리 | `API_CONTRACTS.md`에 current/planned 상태가 명시됨 |
| 2 | Backend 계약 검증 / 패치 | `pytest backend/api/tests`, `python scripts/validate_architecture.py`, route와 API 계약 불일치, error response 점검 | 실행한 명령과 결과 기록, 불일치 제거 또는 이슈화 |
| 3 | Bus Info Gateway 통합 강화 | stopId fallback, `arrivals[].updatedAt` 보정 유지, empty arrivals 반환, public_data 예외를 backend error로 변환 | 앱이 처리 가능한 bus info 응답/오류 기준 확립 |
| 4 | Bus Info Gateway 테스트 보강 | 정상 stopId, 없는 stopId, missing updatedAt, empty arrivals, public_data exception 테스트 | backend 테스트에 gateway 회귀 시나리오 기록 |
| 5 | Ride Request Lifecycle 완성 | 승객 요청 생성/조회, 기사 요청 목록, 기사 수락, 상태 변경, 취소/완료 처리 | `REQUESTED`, `ACCEPTED`, `ARRIVING`, `BOARDING`, `COMPLETED`, `CANCELLED` 흐름 명시 |
| 6 | Ride Request 테스트 / 상태 전이 검증 | `REQUESTED -> ACCEPTED`, `ACCEPTED -> COMPLETED`, `COMPLETED -> ACCEPTED` 금지, 없는 id 404 | 상태 전이 테스트 추가 또는 미구현 항목 기록 |
| 7 | Safety Event API 초안 | `POST /safety-events`, `GET /safety-events/recent`, `OBSTACLE_DETECTED`, `BUS_APPROACHING`, `BEACON_NEAR`, `USER_OFF_ROUTE`, `CROSSWALK_RISK` | planned/current 상태와 schema 초안 기록 |
| 8 | Safety Event 테스트 / mock 연동 | mock event 생성, 저장/조회, invalid event type, UTC timestamp 검증 | safety event mock 테스트 기준 확립 |
| 9 | 환경변수 / mock-live 모드 정리 | `PUBLIC_DATA_USE_MOCK`, `PUBLIC_DATA_BASE_URL`, `FIREBASE_USE_MOCK`, `FCM_USE_MOCK`, `APP_ENV` | `.env.example`, `ENVIRONMENT_VARIABLES.md`와 일치 |
| 10 | 장애 상황 복구 / 에러 응답 정리 | timeout, missing env, invalid stopId, public_data unavailable, firebase unavailable | 앱이 처리 가능한 error response 구조 확보 |
| 11 | 통합 smoke script 작성 | `scripts/smoke_backend_integration.py` 계획 또는 작성 지침: `/health`, `/bus-info`, ride request 생성, driver 조회, status update | smoke 절차와 실행/미실행 결과 기록 |
| 12 | 최종 회귀검증 / 문서 정리 | architecture validation, backend pytest, smoke, `PATCH_NOTES.md`, 공통 진행사항, validation result 갱신 | 최종 결과와 남은 리스크 문서화 |

## 5. 김도성 - Public Data / AI Vision

| Section | Goal | 작업 내용 | 완료 기준 |
|---|---|---|---|
| 1 | Public Data Client 계약 정리 | `DataGoKrClient` 입력/출력/환경변수, serviceKey, baseUrl, timeout, mock/live provider 분리 | public_data 계약 문서화 |
| 2 | Public Data Client 검증 | baseUrl fallback, missing API key, timeout, invalid response, mock fixture loading | 테스트 또는 검증 절차 기록 |
| 3 | BusArrivalsService 정규화 강화 | stopId, busRouteName, arrivalMinutes, isLowFloor, congestionLevel, updatedAt | backend/shared contract와 필드 매핑 명시 |
| 4 | BusArrivalsService 테스트 보강 | 도착정보 있음/없음, 저상버스 있음/없음, 혼잡도 누락, 도착시간 누락 | fixture와 테스트 기준 기록 |
| 5 | 저상버스 / 접근성 필터 강화 | low floor bus 우선 표시, unknown 안전 처리, 필터 기준 문서화 | 앱 표시 기준과 안전 fallback 명시 |
| 6 | Backend Gateway와 계약 검증 | backend schema와 public_data schema 비교, 필드명 불일치 제거, updatedAt 처리 위치 명확화 | backend gateway compatibility 기록 |
| 7 | AI Vision Safety Event Schema 설계 | eventType, confidence, source, detectedObject, timestamp, metadata | backend safety event와 호환되는 schema 초안 |
| 8 | Mock AI Inference Pipeline 작성 | sample image path 입력, mock detection 반환, safety event 변환 | mock inference 사용법과 fixture 기록 |
| 9 | AI Vision 클래스 taxonomy 정리 | person, bus, car, bicycle, bollard, stairs, crosswalk, traffic_light, obstacle의 위험도/안내/eventType/threshold | taxonomy와 safety event 매핑 표 |
| 10 | AI Vision mock pipeline 검증 | high/low confidence, unknown class, multiple objects, empty detection | mock pipeline 검증 결과 기록 |
| 11 | Public Data + AI Vision 산출물 통합 정리 | public_data 사용법, AI vision event schema, mock inference 사용법, fixture 목록 | 후행 팀원이 읽을 통합 README 보강 |
| 12 | 최종 검증 / 문서 정리 | public_data tests, mock fixtures, schema consistency, backend gateway compatibility, 김도성 보고서/공통 진행사항 갱신 | V2 결과와 미구현 후속 항목 명시 |

## 6. 안준환 - Sensor / BLE / Audio Cue

| Section | Goal | 작업 내용 | 완료 기준 |
|---|---|---|---|
| 1 | Sensor/BLE 인터페이스 정리 | BeaconScanner, BeaconSignal, ProximityEvent, RSSI, estimatedDistance, beaconId, signalLevel, direction, timestamp | sensor contract 문서화 |
| 2 | Sensor 모델 검증 | null, unknown beacon, invalid RSSI, timestamp, distance 변환 | 모델 검증 기준 기록 |
| 3 | RSSI 거리 추정 로직 보강 | near, medium, far, unknown. 정밀 m보다 구간 안정화 우선 | 신호 구간 기준 명시 |
| 4 | RSSI / smoothing 테스트 | 연속 강한 신호, 약한 신호, 튀는 신호, 신호 끊김 | smoothing 회귀 기준 기록 |
| 5 | Proximity Event Stream 설계 | `BEACON_NEAR`, `BEACON_LOST`, `APPROACHING_STOP`, `LEAVING_STOP` | event stream contract 초안 |
| 6 | Event Stream mock/replay 검증 | mock beacon sequence, replay fixture, event transition test | fixture 기반 검증 가능 |
| 7 | Audio Cue Mapping 설계 | `BEACON_NEAR`, `BUS_APPROACHING`, `OBSTACLE_DETECTED`에 대한 안내 문장 | 앱/TTS가 사용할 cue 매핑 문서화 |
| 8 | Audio Cue Factory 검증 | known event, unknown event, repeated event, priority conflict | cue 우선순위와 fallback 기준 |
| 9 | Sensor와 Passenger App 연결 준비 | sensor service interface, stream subscription, dispose lifecycle, permission status | 윤현섭 앱 연동을 위한 interface 명시 |
| 10 | 앱 lifecycle / 권한 처리 검증 | 권한 없음/거부, 앱 재시작, 스캔 중지/재개 | 앱 lifecycle 리스크 기록 |
| 11 | Sensor Debug Fixture 정리 | `mock_beacon_sequence.json`, `sensor_replay_guide.md`, sample proximity events | debug fixture 목록과 사용법 |
| 12 | 최종 검증 / 문서 정리 | 안준환 보고서, sensor README, 공통 진행사항 갱신 | V2 sensor/audio cue 결과 정리 |

## 7. 윤현섭 - Flutter Passenger / Driver App

| Section | Goal | 작업 내용 | 완료 기준 |
|---|---|---|---|
| 1 | Flutter BackendApiClient 정리 | baseUrl, timeout, JSON decode, error handling, mock/live mode switch | 앱 API client 기준 명시 |
| 2 | `/health` 연동 검증 | `/health` 호출, 연결 성공/실패 UI, timeout UI | backend 연결 상태 표시 가능 |
| 3 | Passenger Bus Arrivals 연동 | stopId 입력 또는 mock stopId, 도착정보 목록, 저상버스 여부, 도착시간 | bus arrivals current API와 연결 |
| 4 | Bus Arrivals UI 검증 / 에러 처리 | 도착정보 있음/없음, 서버 실패, loading, 잘못된 stopId | UX fallback과 오류 표시 명시 |
| 5 | Passenger Ride Request 생성 연동 | `POST /ride-requests`, 성공 UI, request id 저장, 현재 상태 표시 | 승객 요청 생성 흐름 연결 |
| 6 | Passenger Ride Request 상태 조회 검증 | `REQUESTED`, `ACCEPTED`, `ARRIVING`, `BOARDING`, `COMPLETED`, `CANCELLED` | 상태별 UI 기준 |
| 7 | Driver App 요청 목록 연동 | `GET /driver/ride-requests`, 요청 카드, 위치/정류장 정보, 상태 표시 | 기사 앱 목록 연결 |
| 8 | Driver App 수락/상태 변경 검증 | ACCEPT, ARRIVING, BOARDING, COMPLETED, Passenger App 상태 변경 확인 | driver/passenger 상태 흐름 확인 |
| 9 | VoiceGuideService 실제 데이터 연결 | 저상버스 도착, 요청 전달, 기사 수락 등 실제 API 기반 문장 생성 | TTS 문장 생성 기준 |
| 10 | 접근성 / TTS / STT 검증 | TTS 중복 방지, STT 실패 처리, semantic label, 큰 글씨, 버튼 접근성 | 접근성 회귀 기준 |
| 11 | Sensor/Safety Event 표시 연결 | `BEACON_NEAR`, `OBSTACLE_DETECTED`, `BUS_APPROACHING` 화면 경고와 음성 안내 | mock event stream 표시 가능 |
| 12 | Flutter 앱 최종 정리 / 회귀검증 | flutter analyze/test 가능 시 실행, 앱 실행, backend 연결, mock/live mode, 윤현섭 보고서/실행법 갱신 | 실행/미실행 결과를 사실대로 기록 |

## 8. 섹션별 제출 형식

```text
SECTION_RESULT:
SUMMARY:
CHANGED_FILES:
IMPLEMENTED:
NOT_IMPLEMENTED:
TEST_COMMANDS:
TEST_STATUS:
KNOWN_ISSUES:
NEXT_SECTION_DEPENDENCIES:
```

## 9. 완료 기준

각 섹션은 다음 항목을 남겨야 완료로 본다.

- 관련 문서 업데이트
- 변경 파일 목록 기록
- 테스트 명령 기록
- 미구현 사항 명시
- 다음 섹션 의존성 명시
- mock/live 여부 명시
- 실제 실행하지 않은 테스트는 PASS라고 쓰지 않기

## 10. 다음 섹션 의존성 규칙

- 윤현섭 섹션 3은 현석 섹션 1~3, 김도성 섹션 1~3의 API/schema 안정화에 의존한다.
- 윤현섭 섹션 5~8은 현석 섹션 5~6의 ride request lifecycle에 의존한다.
- 현석 섹션 7~8은 김도성 섹션 7~10, 안준환 섹션 5~8의 safety event schema와 연결된다.
- 윤현섭 섹션 11은 현석 섹션 7~8, 김도성 섹션 8~10, 안준환 섹션 5~8에 의존한다.
- 9~10섹션은 모든 팀원이 mock/live, error handling, 권한/환경변수 경계를 맞추는 단계다.
- 11~12섹션은 모든 팀원이 회귀검증과 문서 정리를 수행하는 단계다.
