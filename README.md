# MOBI
### Spatial Audio and AI 기반 대중교통 이용 보조 시스템

**MOBI는 시각장애인이 대중교통을 이용할 때 필요한 정보를 음성과 방향성 소리로 전달하기 위한 프로젝트입니다.** 버스 노선 검색, 카메라 기반 주변 객체 인식, BLE 비콘 신호, 머리 방향 센서를 하나의 모바일 경험으로 연결합니다.

노선과 도착 정보를 찾는 일뿐 아니라, 화면 속 버스·출입문·주변 장애물의 위치를 파악하는 과정에서도 시각 정보에 의존하게 됩니다. MOBI는 이러한 정보를 듣기 쉬운 형태로 바꾸어 대중교통 이용의 정보 접근성을 높이는 것을 목표로 합니다.

> 현재는 연구·시연용 시스템입니다. 인식 결과와 방향 소리는 정보 보조 수단이며, 실제 위험 판단·안전한 이동 경로·승차 가능 여부를 보장하지 않습니다.

## 주요 기능

| 기능 | 제공하는 경험 |
| --- | --- |
| 계정 기반 시작 화면 | 로그인 후 노선 검색·장애물 탐지로 이동하고 우측 상단에서 로그아웃 |
| 음성·텍스트 노선 검색 | 목적지나 정류장을 입력해 버스 경로와 관련 정보를 확인 |
| 데이터 상태 안내 | 공개 API·캐시·모의 데이터·알 수 없는 출처와 갱신 시각을 구분 |
| 카메라 객체 인식 | 화면에서 버스, 문, 정류장 후보와 보도 주변 객체를 탐지 |
| 장면 요약·자세히 듣기 | 단일·복수 객체의 화면 위치를 음성으로 설명하고 최신 결과만 재안내 |
| 방향성 오디오 | 화면 위치 또는 보정한 상대 방향에 따른 스테레오 소리 제공 |
| BLE·WT 연동 시연 | 지정 비콘 신호와 머리 회전을 함께 관찰하고 장치별로 독립 제어 |
| 접근성 | 주요 기능 버튼의 의미·안내 제공, TalkBack을 고려한 UI와 큰 글씨 대응 |

운전자 앱과 Backend에는 기사·승객 연계, 승차 요청 및 운행 정보 처리를 위한 모듈도 분리되어 있습니다. 실제 운영 서비스 연결과 검증 범위는 각 모듈 문서를 따릅니다.

## 서비스 구성

```text
사용자: 목적지 입력 / 음성 입력
              │
              ▼
      Flutter 승객 앱 ◀────▶ FastAPI Backend
         │      │                 │
         │      │                 ├─ 공공 교통 데이터 연동
         │      │                 └─ Firebase 인증·RTDB·FCM 연계
         │      │
         │      └─ 카메라 → 로컬 YOLO/TFLite 추론 → 최신 장면 요약
         │
         └─ BLE 비콘·WT 방향 센서 → 상대 방향 / 신호 상태
                                      │
                                      ▼
                           TTS · 방향성 오디오
```

카메라 로컬 추론과 Backend API 연동은 구분된 경로입니다. 임시 동시 장치 테스트 화면은 로컬 카메라 추론을 사용하며, 이를 서버 영상 업로드 기능으로 해석하지 않습니다.

## AI Vision: YOLO 모델

현재 Android 카메라 경로는 **YOLO11n 기반 통합 모델**을 TFLite로 실행합니다.

- 모델 자산: `yolo11n_unified_bus_obstacle_stop_v4_float32.tflite`
- 대상 클래스: `bus`, `bus_door`, `parked_pm`, `pole`, `tree_trunk`, `bus_stop`
- 입력: RGB float32, `640 × 640`, 정규화 `0~1`
- 처리: 비율 유지 letterbox → 추론 → 클래스별 NMS → 원본 카메라 좌표 복원
- 출력 활용: 화면 내 위치별 장면 요약, 최신 장면의 상세 음성 안내와 방향 소리

학습 과정은 데이터 수집·라벨 검토, 클래스 매핑, 분할 검증, YOLO 학습·평가, TFLite 변환으로 구성됩니다. 기존 버스·문과 보도 객체 데이터를 통합하되 학습·검증·테스트 분할을 구분하며, 새 가중치를 만들었다고 앱 기본 모델로 자동 교체하지 않습니다. 초기 학습 파이프라인의 3·4클래스 설정과 현재 통합 모델의 6클래스 설정도 구분합니다.

정류장 후보와 작은 객체에는 오탐·미탐이 있을 수 있습니다. 박스 크기에서 검증되지 않은 실제 거리를 추정하지 않으며, 화면 위치를 안전한 이동 방향으로 단정하지 않습니다.

- [현재 통합 모델과 입출력 규격](mobi-smart-transport-ai/ai_vision/UNIFIED_MODEL_FIELD_TEST_HANDOFF.md)
- [학습·데이터 검토 파이프라인](mobi-smart-transport-ai/ai_vision/training/README.md)
- [추론 파이프라인](mobi-smart-transport-ai/ai_vision/pipelines/README.md)

## 공간 음향·BLE·WT

**방향성 오디오**는 좌우 위치를 소리로 표현합니다. 화면 좌표 기반 안내와 머리 방향을 사용하는 보정 모드는 서로 다른 기준을 가지며, 사용 중인 기준을 구분합니다. 장면이 오래되거나 중지된 경우 이전 결과를 계속 재생하지 않도록 제어합니다.

**BLE 비콘**은 사용자가 지정한 버스 번호와 MAC의 대응 관계를 사용합니다. RSSI 변화는 시연용 소리 반복 간격에 반영되지만 거리(m)나 실제 버스의 접근을 증명하지 않습니다.

**WT 방향 센서**는 기준 방향을 보정한 뒤 머리 회전과 상대 방향을 관찰합니다. 현재 단계는 통제된 정지 환경을 위한 것이며 사용자의 위치 이동을 추적하지 않습니다.

임시 테스트 화면에서는 BLE·WT와 카메라를 두 페이지로 나누어 조작합니다. 페이지를 바꿔도 각 기능의 상태를 유지하며 장치를 독립적으로 시작·중지할 수 있습니다.

## 기술 스택

| 영역 | 기술 |
| --- | --- |
| 모바일 | Flutter · Dart, Android Kotlin 네이티브 연동 |
| 접근성·음성 | Flutter semantics, STT, TTS |
| 센서·출력 | Bluetooth LE, WT 방향 데이터, 스테레오 오디오 |
| 모바일 추론 | TensorFlow Lite, `tflite_flutter`, 카메라 프레임 처리 |
| 모델 학습 | Python, Ultralytics YOLO11n |
| API | FastAPI, Pydantic, HTTPX, JSON Schema |
| 서비스 연계 | Firebase Authentication · Realtime Database · FCM, 공공 교통 데이터 |
| 검증 | Flutter widget/unit test, pytest, Firebase 로컬 에뮬레이터 |

정확한 의존성 버전은 각 모듈의 `pubspec.yaml`·lock 파일과 `requirements*.txt`를 기준으로 합니다.

## 저장소 구조

주 개발 코드는 `mobi-smart-transport-ai/` 아래에 있습니다.

```text
mobi-smart-transport-ai/
├─ apps/
│  ├─ passenger_app/       승객 앱
│  └─ driver_app/          운전자 앱
├─ backend/api/            API와 서비스 로직
├─ services/public_data/   공공 교통 데이터 연동
├─ packages/               인증·센서·공유 계약
├─ ai_vision/              데이터 준비·학습·모델·추론
├─ infrastructure/         Firebase 등 환경 구성
├─ scripts/                검증·패키징·빌드 도구
└─ docs/                   요구사항·설계·실행 안내
```

## 시작하기

Flutter SDK, Python 개발 환경, Android SDK가 필요합니다. Android 빌드에는 JDK 21로 검증한 구성을 사용합니다. Firebase 앱 설정과 Backend 주소는 자신의 개발 환경에 맞게 준비하세요. 계정 비밀번호·관리자 키·토큰은 저장소나 앱 설정에 넣지 않습니다.

```bash
git clone https://github.com/Yoonhsub/Integrated-Safety-Assurance-System-using-Spatial-Audio-and-AI.git
cd Integrated-Safety-Assurance-System-using-Spatial-Audio-and-AI/mobi-smart-transport-ai
```

승객 앱 의존성과 코드 확인:

```bash
cd apps/passenger_app
flutter pub get
flutter analyze
flutter test
```

정상 로그인 흐름의 Android debug APK 빌드 (`mobi-smart-transport-ai/`에서 실행):

```text
python scripts/prepare_passenger_android.py --settings <normal-android.json> --flutter <flutter-executable> --build
```

이 빌드는 앱을 설치하거나 실행하지 않습니다. 설정 형식과 Backend 실행은 아래 문서를 먼저 확인하세요.

- [개발 환경 설정](mobi-smart-transport-ai/docs/rw/SETUP.md)
- [환경 변수 안내](mobi-smart-transport-ai/docs/rw/ENVIRONMENT_VARIABLES.md)
- [승객 앱 안내](mobi-smart-transport-ai/apps/passenger_app/README.md)
- [API 계약](mobi-smart-transport-ai/docs/rw/API_CONTRACTS.md)
- [하드웨어 없는 검증 방법](mobi-smart-transport-ai/docs/rw/HARDWARE_FREE_VALIDATION.md)
- [상세 개발·검증 기록](mobi-smart-transport-ai/docs/rw/LOCAL_INTEGRATION_PROGRESS_2026-11-14.md)

## 팀과 역할

저장소의 [모듈 소유권 정의](mobi-smart-transport-ai/module_ownership.json)를 기준으로 정리했습니다.

| 팀원 | 담당 영역 |
| --- | --- |
| 윤현섭 | 승객·운전자 Flutter 앱, 음성 입출력, 접근성, Backend API, Firebase 및 기사·승객 연계, 공공데이터 연동 |
| 안준환 | 모바일 센서, BLE 비콘과 방향 데이터 |
| 김도성 | AI Vision |


## 사용 범위와 주의사항

- 이 프로젝트는 안전 인증 제품이나 보행 보조 도구의 대체재가 아닙니다. 실제 인식률, 재연결, 센서 드리프트, 이어폰 좌우 출력과 음향 지연은 장치별 검증이 필요합니다.
- `MOCK`·`CACHE`·공개 API 결과를 구분해야 합니다. API 응답도 실제 차량 식별이나 승차 확인을 뜻하지 않으며 관측 시각이 없으면 최신으로 간주하지 않습니다.
- WT 저장 설정이 손상되거나 읽히지 않으면 연결을 차단하고 명시적인 설정 복구 후 다시 연결합니다. 저장 설정이 없는 경우의 기본 주소를 포함해 실제 연결 대상은 사용자가 확인해야 합니다.
- Android 에뮬레이터의 시스템·앱 ANR 원인이 아직 분리되지 않아 실제 UI 탐색 검증이 완료된 것으로 보지 않습니다.

## 모델·데이터 라이선스

코드, 모델 가중치, 학습 데이터와 음향 자산의 이용 조건은 각각 확인해야 합니다. Ultralytics와 사용한 Roboflow·AIHub 데이터의 정확한 릴리스 및 재배포 허용 범위는 아직 확정되지 않았습니다. 연구·캡스톤 목적이라는 이유만으로 자유로운 재배포를 가정하지 마세요. SADIE 자료의 NOTICE·LICENSE·manifest 등 기존 고지는 유지해야 하며, 공개 배포 전 포함 자산별 권리를 확인해야 합니다.
