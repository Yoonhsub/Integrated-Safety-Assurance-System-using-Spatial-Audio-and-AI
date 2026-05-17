# MOBI Smart Transport AI Agent System

시각장애인과 노약자를 위한 스마트 교통 AI 에이전트 시스템의 **공통 프로젝트 아키텍처 스캐폴딩**입니다.

이 저장소는 세부 기능을 완성 구현하는 목적이 아니라, 요구사항명세서를 충실히 반영한 전체 시스템의 거시적 뼈대를 잡고 팀원별 개발 경계를 명확히 하기 위한 출발점입니다.

## 현재 상태와 V2 진행 방향

4~5월 구현 파트는 팀원별 mock-first 모듈이 대체로 구현 완료된 상태입니다.
현재 기준 `python scripts/validate_architecture.py`는 PASS이며, backend pytest는 29 passed 상태로 기록되어 있습니다.

이제 프로젝트는 발표 자료 작성이 아니라 **통합 MVP 고도화 V2** 단계로 넘어갑니다. V2의 목표는 "각자 만든 섹션을 실제 앱-백엔드 중심의 통합 가능한 구조로 연결한다"입니다.

V2는 총 12섹션으로 진행합니다. 홀수 섹션은 구현 중심, 짝수 섹션은 검증/패치/문서화 중심입니다. 팀 전체가 같은 섹션 번호 흐름을 공유하되, 각 팀원은 자신의 담당 영역만 수정합니다.

V2 섹션 계획의 기준 문서는 `docs/rw/V2_SECTION_PLAN.md`입니다.

## 새 zip 수령 후 읽기 순서

새 zip 파일을 받은 팀원은 아래 순서대로 문서를 확인합니다.

1. `docs/rw/README.md`
2. `docs/rw/V2_SECTION_PLAN.md`
3. `docs/rw/선행작업의존성 정리.md`
4. `docs/rw/API_CONTRACTS.md`
5. `docs/rw/SETUP.md`
6. 자신의 팀원별 최종 개발 보고서 또는 관련 README

이 문서 묶음은 발표 대비 문서가 아니라 V2 개발 진행 문서입니다. 발표 자료 작성, 발표 스크립트, 슬라이드 제작은 이번 문서 기준의 범위가 아닙니다.

## 핵심 원칙

1. 팀원별 담당 영역을 폴더/패키지 단위로 분리한다.
2. 개인별 AI 에이전트는 자기 담당 영역 밖의 코드를 임의로 수정하지 않는다.
3. 공통 계약(`packages/shared_contracts`)은 개인 구현 편의를 위해 마음대로 바꾸지 않는다.
4. 4월 MVP 범위와 향후 확장 범위를 분리한다.
5. 헤드트래킹, 고도화된 공간음향, AI 비전 실시간 통합 등은 향후 구현을 위한 프레임만 둔다.

## 저장소 구조 요약

```txt
apps/
  passenger_app/          # 윤현섭: 사용자 Flutter 앱 UI/STT/TTS/접근성/데이터 렌더링
  driver_app/             # 윤현섭: 기사용 Flutter 앱 UI/탑승 요청 화면
backend/
  api/                    # 심현석: FastAPI, Firebase, 지오펜싱, FCM, 매칭 파이프라인
services/
  public_data/            # 김도성: 공공데이터 API, 버스 도착/위치/저상버스 필터링
packages/
  mobile_sensors/         # 안준환: BLE 비콘, RSSI, 스마트폰 방향 센서
  shared_contracts/       # 공통 API/이벤트/DB 계약. 단독 임의 수정 금지
ai_vision/
  dataset_plan/           # 김도성: 2학기 AI 비전 데이터셋/라벨링 계획
  model_research/         # 김도성: 모바일 경량 모델 리서치
future_modules/
  head_tracking/          # 향후 헤드트래킹 확장 프레임. 4월 구현 금지
  spatial_audio/          # 향후 공간음향 확장 프레임
infrastructure/
  firebase/               # Firebase RTDB/FCM/Rules/Schema 초안
scripts/                  # 저장소 구조 검증/개발 보조 스크립트
.github/                  # CODEOWNERS, PR 템플릿
```

## 4월 MVP 담당 경계

| 담당자 | 담당 폴더 | 4월 구현 초점 |
|---|---|---|
| 윤현섭 | `apps/passenger_app`, `apps/driver_app` | Flutter UI, STT/TTS, 접근성, API 응답 렌더링 |
| 안준환 | `packages/mobile_sensors` | BLE 비콘 수신, RSSI 거리 추정, 스마트폰 방향 센서 |
| 심현석 | `backend/api`, `infrastructure/firebase` | FastAPI, Firebase, 지오펜싱, FCM, rideRequests |
| 김도성 | `services/public_data`, `ai_vision` | 공공데이터 버스 API, 저상버스 필터링, AI 비전 준비 |

## V2 담당 영역 요약

| 담당자 | V2 역할 | 주요 연결 대상 |
|---|---|---|
| 현석 | Backend / Integration Backbone | API 계약, bus_info_gateway, rideRequests, safety events, 에러 응답 |
| 김도성 | Public Data / AI Vision | public_data 정규화, backend gateway 계약, AI vision safety event schema |
| 안준환 | Sensor / BLE / Audio Cue | beacon proximity event, RSSI smoothing, audio cue mapping, sensor fixture |
| 윤현섭 | Flutter Passenger / Driver App | backend API client, bus arrivals UI, ride request UI, safety event 표시와 TTS |

## 실행 가능성에 대한 안내

이 저장소는 초기 아키텍처 스캐폴딩에서 V2 통합 준비 단계로 이동했습니다. 일부 파일은 의도적으로 stub/TODO 상태입니다. 각 담당자는 자기 에이전트 필독 문서와 공통 프롬프트를 읽은 뒤, V2 섹션 계획을 함께 확인하고 12단계 섹션 방식으로 구현을 진행해야 합니다.

## 빠른 구조 검증

```bash
python scripts/validate_architecture.py
```


## AI 에이전트 필독 문서

모든 팀원의 생성형 AI 에이전트는 코드 수정 전 `docs/read/AGENT_REQUIRED_READING.md`의 읽기 순서를 따른다. 핵심 순서는 다음과 같다.

1. `docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md`
2. `docs/read/AGENT_REQUIRED_READING.md`
3. `docs/01_요구사항명세서.md`
4. `docs/agent_required_reading/01_요구사항명세서.md`
5. `docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md`
6. `docs/rw/README.md`
7. `module_ownership.json`
8. `.github/CODEOWNERS`
9. 자신의 팀원 전용 에이전트 필독사항
10. `docs/rw/선행작업의존성 정리.md`

`.docx` 파일은 전체 프로젝트 배경 이해에 도움이 되는 제출/공유용 보조 원문이다. 에이전트가 참고할 수는 있지만, 공식 계약·정합성 판단 기준은 markdown 문서와 machine-readable schema를 우선한다.

이 저장소는 완성 기능 구현물이 아니라 요구사항명세서 전체를 수용하기 위한 공통 아키텍처 스캐폴딩이다. 각 팀원의 에이전트는 자기 담당 디렉터리 외부를 임의로 수정하지 않는다.
