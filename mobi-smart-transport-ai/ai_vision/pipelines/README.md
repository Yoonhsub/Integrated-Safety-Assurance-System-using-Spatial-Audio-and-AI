# AI Vision Inference Pipeline

이 폴더는 DetectionResult contract, mock provider, local single-image YOLO inference,
deterministic single-frame SafetyInterpreter를 제공한다.
YOLO provider는 `ultralytics` 패키지를 명시적으로 설치하고 local model weight 경로를 전달해야
사용할 수 있다.

---

## 1. 추론과 안전 이벤트 흐름

```txt
VisionInferenceRequest
→ VisionProvider
→ DetectionResult
→ SafetyInterpreter
→ SafetyInterpretation
→ HTTP transport client (AI Vision process)
→ POST /ai-vision/events
→ backend transport validation and adapter
→ SafetyEventCreate
→ existing SafetyEventService
→ Firebase / mock storage
```

`VisionInferenceRequest`가 한 입력의 frame ID, 캡처 시각, source, provider-neutral payload를
묶는다. 현재 source는 로컬 `image_file`만 지원하고 payload는 `pathlib.Path`다. 요청 생성 시
UUID frame ID, timezone이 포함된 ISO 8601 캡처 시각, 파일 존재 여부를 확인한다. webcam/video
source와 ndarray/PIL payload는 아직 지원하지 않는다.

`VisionProvider`가 request를 받아 detector 결과인 `DetectionResult`를 반환한다.
`SafetyInterpreter`는 `../dataset_plan/class_taxonomy.json`의 클래스 임계값, reason, 위험도,
안내 문구를 사용해 한 프레임으로 근거를 세울 수 있는 경우에만 별도 `Safety Event`를 만든다.
event 생성 여부와 추론 결과 상태는 분리한다: 정상 결과에서 조건을 만족하는 규칙이 없으면
`no_event`, 입력 DetectionResult가 `unavailable` 또는 `error`이면 그 상태를 그대로 전달한다.
추론 실패는 위험 없음으로 처리되지 않는다.

v1 단일 프레임 규칙은 `bus_stop_recognized`와 `bus_door_visible`이다. `approaching_bus`에는
버스가 사용자 정류장에 접근한다는 시간/정류장 맥락이 필요하고, `off_sidewalk`에는 사용자의
위치 관계, `obstacle_ahead`에는 보행 경로와의 관계, `tactile_paving_lost`에는 이전 프레임의
점자블록 추적이 필요하다. 이 상태 정보가 없는 단일 detection으로 해당 이벤트를 주장하지 않는다.
특히 bus 검출만으로 접근 또는 위험을 단정하지 않는다. bbox는 정규화된 이미지 위치일 뿐 거리나
사용자와의 충돌 가능성을 나타내지 않는다.

`frameId`, `capturedAt`, `source`는 request가 소유하며 provider 결과에도 그대로 전달한다.
mock fixture에 저장된 같은 필드는 입력 metadata로 덮어쓴다. model metadata와 detections는
provider가 반환하며, 향후 실제 provider도 동일한 metadata 전달 규칙을 따라야 한다.

현재 구현 범위:

- `DetectionResult` Python representation과 shared JSON Schema
- `VisionInferenceRequest` 입력 representation
- typed `VisionProvider` interface 및 명시적 mock provider 선택
- `MockVisionProvider`의 DetectionResult fixture 시나리오 반환
- `YOLOVisionProvider`의 로컬 단일 이미지 inference
- taxonomy 기반 `SafetyInterpreter` 및 내부 Safety Event representation
- backend-side AI Vision adapter의 `SafetyEventCreate` 변환과 기존 service 저장
- 별도 프로세스용 HTTP client와 FastAPI ingestion endpoint
- event / no_event / unavailable / error의 shared request/response contract

아직 구현되지 않은 범위:

- 프로젝트 custom dataset으로 학습한 모델
- webcam 및 video stream 처리
- provider/backend startup을 연결하는 production orchestration
- 자동 재시도, 로컬 큐, 오프라인 재전송, 인증/인가
- passenger app integration

mock provider는 실제 전달된 frame을 분석하지 않고 fixture 시나리오를 반환한다.
기존 `mock_inference_pipeline.py`와 `mock_safety_events.json`은 Safety Event demo용으로
별도 유지한다.

MockVisionProvider는 반환 전에 DetectionResult fixture를 shared JSON Schema로 검증하므로
`jsonschema`가 필요하다. AI Vision 실행 환경은 프로젝트 루트에서
`python -m pip install -r ai_vision/requirements.txt`로 준비한다. Backend 개발 환경의
`backend/api/requirements-dev.txt`는 contract test에 필요한 `requirements-base.txt`만
포함하며, 무거운 Ultralytics/PyTorch runtime은 추가하지 않는다.

### 1.1 YOLO single-image provider

첫 개발 대상 pretrained model은 **YOLO11n**이다. repository model research의 COCO 기준에서
YOLO11n은 YOLOv8n보다 mAP가 높고(39.5 vs 37.3), parameter도 적다(2.6M vs 3.2M).
Ultralytics [YOLO11 문서](https://docs.ultralytics.com/models/yolo11)는 이를 권장 모델로 제시하고,
[YOLOv8 문서](https://docs.ultralytics.com/models/yolov8)도 계속 제공한다.
두 버전은 동일한 Ultralytics/PyTorch runtime을 사용하므로 YOLOv8n을 택해도 Python/Windows
설치 경로는 크게 달라지지 않는다. 이 선택은 pretrained 개발 baseline이며, custom dataset
평가 후 최종 모델 선정은 별도로 해야 한다. COCO CPU ONNX benchmark는 YOLO11n 56.1ms,
YOLOv8n 80.4ms로 안내되지만, 로컬 PyTorch CPU 시간이나 실시간 보장은 아니다.

AI Vision runtime 의존성 설치:

```powershell
python -m pip install -r ai_vision/requirements.txt
```

Ultralytics가 OpenCV Python package를 직접 의존성으로 선언하므로 `opencv-python`을 별도로
중복 선언하지 않는다. YOLO weight와 입력 이미지는 저장소에 넣지 않는다. 공식 Ultralytics
공식 [YOLO11 asset release](https://github.com/ultralytics/assets/releases/tag/v8.3.0)에서
`yolo11n.pt`를 수동으로 준비하고 repository 밖의 경로에 보관한다. provider는
존재하는 model file path만 받고, 파일이 없으면 다운로드하지 않고 configuration error를 낸다.

실제 inference는 명시적으로 opt-in하여 실행한다. 설치 및 weight 준비 없이 test suite가 모델을
다운로드하거나 로드하지 않는다.

```powershell
python scripts/smoke_yolo_inference.py `
  --model-path "C:\models\yolo11n.pt" `
  --image "C:\data\bus.jpg"
```

COCO pretrained model 중 현재 project taxonomy와 안전하게 직접 대응하는 class는 `bus`뿐이다.
`person`은 개인정보·taxonomy 정책 때문에 버린다. `stop sign`은 bus stop으로 간주하지 않는다.
YOLO result에서 mapping되지 않은 class는 DetectionResult에 넣지 않는다. 따라서 pretrained
결과의 빈 detection은 정상 추론 결과이며, project safety coverage를 뜻하지 않는다.
`bus_door`, `bus_stop`, `roadway`, `sidewalk`, `obstacle`, `tactile_paving`은 정확한 custom
class mapping 또는 project dataset fine-tuning 전까지 검출된 것으로 주장하지 않는다.

### 1.2 DetectionResult와 Safety Event 책임

- **DetectionResult**는 한 프레임의 detector 결과다. schema 버전, 입력 source, 처리 상태,
  frame ID/캡처 시각, 모델 식별 정보, detection 목록을 표현한다. 위험도나 사용자 안내를
  판정하지 않는다.
- **Safety Event**는 DetectionResult를 SafetyInterpreter가 사용자·상황 맥락과 함께 해석한
  결과다. 기존 fixture의 `riskLevel`, `reason`, `primaryClass`, `message`는 이 event 계층에
  속한다. 현재 내부 event는 `eventId`, `frameId`, `capturedAt`, `source`, `riskLevel`, `reason`,
  `primaryClass`, `confidence`, detection summary, `message`와 가능한 `imageSize`/`modelInfo`를
  포함한다. 이 표현은 legacy mock fixture 형식을 유지하면서 source와 primary detection confidence를
  추가한다. 결정적인 ID 생성을 위해 event ID는 frame/reason/class 기준 UUIDv5다.
- backend `SafetyEventCreate`는 `eventType`, `source`, `timestamp`, 선택적 `confidence`/`metadata`
  등을 받는 별도의 contract다. backend-side `AiVisionSafetyEventAdapter`가 이 contract에 맞게
  변환하며, AI Vision interpreter/provider는 backend schema를 알지 않는다. 현재 허용 event type에는
  `bus_stop_recognized`나 `bus_door_visible`와 의미가 맞는 값이 없으므로 기존 값을 오용하지 않고
  additive `VISION_INTERPRETATION` type을 사용한다. reason/risk/class는 문자열 metadata로 유지한다.
- adapter는 `SafetyEventService`에 직접 전달하는 구조다. backend 안에서 loopback HTTP를 거치지 않는다.
  저장 service integration은 fixture 기반으로 검증했지만 실제 provider를 backend startup에 자동 연결하는
  자동 orchestration은 아직 구현되지 않았다. 별도 process/HTTP 경로는 §1.3에서 설명한다.
- `status: "ok"` + 빈 `detections`는 정상 추론 후 검출이 없었다는 뜻이다. `unavailable` 또는
  `error`는 추론 결과가 없으며 둘 다 `error` 정보를 포함하고 `detections`는 빈 배열이어야
  한다. 따라서 실패를 “위험 객체 없음”으로 해석할 수 없다.
- 추론 상태가 아닌 최종 위험 판정은 DetectionResult에 추가하지 않는다. 기존 Safety Event
  fixture는 유지하며, 향후 adapter가 두 계약 사이를 명시적으로 변환한다. DetectionResult
  전체를 현재 backend Safety Event endpoint에 그대로 보낼 수는 없다.

JSON Schema는 `packages/shared_contracts/api/vision_detection.response.schema.json`에 있고,
예제 상태별 데이터는 `fixtures/mock_detection_results.json`에 있다. 이 이름은 detector의
표준 결과 형식을 나타내며, 현재 운영 중인 HTTP API endpoint가 있다는 뜻은 아니다.

`SafetyInterpreter` 결과에는 `event`, `no_event`, `unavailable`, `error` 상태가 있다.
taxonomic threshold 미만 detection과 unknown class는 이벤트 근거에서 제외한다. 이벤트 후보가
여러 개면 reason 위험도(`danger > warn > info`), taxonomy class priority(`high > medium`),
confidence 내림차순, class ID, bbox 좌표, reason code 순으로 선택해 입력 순서와 무관하게
결과를 결정한다. Safety Event의 detection summary는 기존 mock event 필드명 `score`를 사용한다.

backend adapter는 `event`만 `SafetyEventCreate`로 변환한다. `no_event`, `unavailable`, `error`는
payload를 만들지 않으며 저장 service도 호출하지 않는다. backend `source`는 mock provider를
`ai_vision_mock`, Ultralytics provider를 `ai_vision_live`로 구분하고, `inferenceMode`와 정확한
`modelProvider`도 metadata에 둔다. unknown provider는 mock으로 대체하지 않고 거부한다.
DetectionResult의 `capturedAt`은 timezone 검증 후 backend `timestamp`로 전달한다. backend가 생성한
record `eventId`와 구분하도록 원본 vision event ID는 `visionEventId` metadata에 보존한다.

---

### 1.3 Cross-process backend transport

AI Vision 프로세스는 `BackendSafetyEventClient`로 해석 결과만 JSON 전송한다. 이미지,
정규화 bbox 목록, detector raw output은 전송하지 않는다. DTO는
`packages/shared_contracts/api/ai_vision_safety_interpretation.request.schema.json` 및
`ai_vision_safety_interpretation.response.schema.json`을 따른다. backend의
`POST /ai-vision/events`가 Pydantic 계약을 검증하고 backend adapter를 거쳐 기존
`SafetyEventService`를 호출한다. 기존 `POST /safety-events`와 저장 service는 유지된다.

`event`는 HTTP 201 및 저장된 Safety Event를 반환한다. `no_event`, `unavailable`, `error`는
HTTP 200으로 처리 결과를 확인시키지만 `stored: false`, `safetyEvent: null`로 응답하며
저장 service를 호출하지 않는다. status별 field와 reason/class 조합은 schema와 Pydantic에서
검증한다. client는 backend URL과 timeout을 명시적으로 받고 연결/4xx/5xx/invalid response를
서로 다른 예외로 전달한다. 자동 retry나 mock fallback은 하지 않는다.

실제 backend 프로세스가 실행 중일 때 다음 opt-in smoke 명령으로 fixture event를 저장할 수
있다. 실행 시 mock Safety Event가 backend 저장소에 추가된다.

```powershell
python scripts/smoke_ai_vision_backend.py --backend-url http://127.0.0.1:8000
```

AI Vision runtime 설치 명령은 `python -m pip install -r ai_vision/requirements.txt`다.
`httpx`가 transport runtime dependency로 추가되며 backend도 기존 requirements에서 동일한
버전을 사용한다.

## 2. 추론 위치 후보 (2학기 결정)

| 위치 | 장점 | 단점 |
|---|---|---|
| 모바일 단말 (on-device) | 네트워크 지연 0, 프라이버시 강함 | 단말 성능/배터리 제약 |
| 백엔드 (server-side)    | 모델/데이터 갱신 빠름, 단말 부담↓ | 네트워크 지연·대역폭 비용 |
| 하이브리드               | 1차 단말 → 임계 이상 시 백엔드 보강 | 구현 복잡도 ↑ |

4월 단계에서는 **결정하지 않는다** — 윤현섭(Flutter 앱)·심현석(FastAPI 백엔드)·
안준환(센서 패키지)과 2학기 시작 시점에 협의 후 결정. 본 결정은 김도성 단독 결정이
아니라 잠재 협의 사항이며, 결정 시 `docs/rw/선행작업의존성 정리.md`에 새 의존성 ID로
기록될 가능성이 높다.

---

## 3. 향후 인터페이스 후보 (정합성 가이드)

본격 구현 시 다른 팀원 모듈과 연결되는 지점에서 **계약(shared contract) 정의가 필요**해진다.
4월 단계에서는 후보 형태만 메모로 둔다 — 실제 schema는 2학기에 정식 등록한다.

### 3.1 detection 결과 표준 응답 (후보 — 미정)

#### 3.1.1 후보 응답 본문

```json
{
  "frameId": "string (UUID v4)",
  "capturedAt": "string (RFC3339, e.g. 2026-09-01T08:30:00+09:00)",
  "imageSize": { "width": 1920, "height": 1080 },
  "detections": [
    {
      "classId": "bus | bus_door | bus_stop | roadway | sidewalk | obstacle | tactile_paving",
      "bbox": { "x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0 },
      "score": 0.0
    }
  ],
  "modelInfo": {
    "name": "string (e.g. yolov11n)",
    "version": "string (semver, e.g. 0.2.0)"
  }
}
```

#### 3.1.2 필드 의미

```txt
- frameId      : 프레임 식별자. 단말이 생성한 UUID v4. 백엔드/UI 매칭에 사용.
- capturedAt   : 카메라 프레임 캡처 시각. RFC3339(=ISO 8601). UTC 또는 +09:00 KST 둘 다 허용.
- imageSize    : 추론에 사용한 이미지의 픽셀 크기. bbox는 이 크기 기준으로 정규화된 0~1 좌표.
- detections   : 검출된 객체 list. 빈 list 가능(검출 0건).
- detections[].classId : class_taxonomy.json의 7개 id 중 하나.
- detections[].bbox   : 정규화 좌표(0~1). x/y는 좌상단, w/h는 박스 크기.
- detections[].score  : 모델 신뢰도(0~1). 호출자가 임계값으로 필터링 가능.
- modelInfo    : 추론에 사용한 모델 식별. 운영 단계 디버깅·롤백에 사용.
```

#### 3.1.3 계약 강제 사항 (후보)

```txt
- frameId / capturedAt / detections는 필수.
- imageSize / modelInfo는 선택(미정 시 호출자가 안전 기본값 사용).
- detections[].score >= 0.0 이면서 <= 1.0.
- bbox 값은 모두 [0, 1] 범위 (이미지 경계를 벗어나지 않도록 추론 단계에서 clip).
- additionalProperties: false (계약 외 필드 침투 차단).
```

#### 3.1.4 정식 등록 위치 후보

```txt
packages/shared_contracts/api/vision_detection.response.schema.json   (신규)
```

이 schema 등록은 **김도성 단독 결정 금지** — 안준환의 `packages/shared_contracts/**`
영역과 겹치므로 협의 후 등록. 또한 윤현섭(Flutter 사용자 앱이 이 응답을 받아 UI 안내로
변환), 심현석(백엔드가 이 응답을 위험 판단/알림 이벤트로 가공)과도 입력·출력 형식
합의 필요. 본격 등록은 **DEP-FUT-003 후행 시점**(2학기)으로 미룬다.

### 3.2 risk interpretation 출력 (후보 — 미정)

검출 결과를 백엔드/Flutter가 음성·진동·FCM 알림으로 변환하는 단계에서 추가 표준이
필요할 수 있다. 4월 시점에는 형식 결정하지 않음 — 다만 후보 흐름을 메모:

```txt
detection_response → risk_classifier
  → riskLevel : "info" | "warn" | "danger"
  → reason    : "approaching_bus" | "obstacle_ahead" | "off_sidewalk" | ...
  → message   : 사용자에게 보여줄/들려줄 안내 문구 (다국어 후보)
```

위 형식은 4월 시점의 후보일 뿐이며, 2학기 시작 시점에 윤현섭(UX 메시지)·심현석(이벤트
필드)와 협의하여 확정한다.

### 3.3 통합 단계 표기 (4월 시점 단계 흐름)

본 영역(`ai_vision/`)이 다른 팀 모듈과 통합되는 시점·범위를 단계별로 정리한다.
각 단계의 시점은 김도성 단독 결정이 아니므로 **2학기 팀 회고에서 확정**된다.

```txt
┌─────────────────────────────────────────────────────────────────────────┐
│ 단계 0 — 4월 (현재): 영역 분리                                            │
│  - ai_vision/은 데이터 계획·라벨링 표준·모델 비교·파이프라인 메모만 보유    │
│  - 다른 팀 모듈과 직접 연결 없음. 학습/추론 코드 미작성.                    │
└─────────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────────┐
│ 단계 1 — 2학기 초: 데이터셋 구축 + 모델 학습                              │
│  - data_collection_guide.md 기준으로 2학기 본격 수집 시작                 │
│  - labeling_standards.md 기준으로 본격 라벨링 + IAA 측정                  │
│  - model_candidates 중 1~2개 후보로 fine-tuning 시작                     │
│  - 다른 팀 모듈과 여전히 직접 연결 없음                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────────┐
│ 단계 2 — 2학기 중반: 추론 파이프라인 단독 구현                              │
│  - 학습된 모델로 단독 추론 데모 제작 (단말 또는 백엔드 중 선택)             │
│  - vision_detection.response.schema.json 후보를 packages/shared_contracts/│
│    에 정식 등록 (안준환과 협의 후)                                        │
│  - 본 schema는 다른 팀이 코드로 import해 사용 가능                         │
└─────────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────────┐
│ 단계 3 — 2학기 후반: 다른 팀 모듈과 통합                                   │
│  - 윤현섭(Flutter): vision detection 결과를 UI/음성 안내로 변환             │
│  - 심현석(백엔드): vision detection 결과를 위험 이벤트로 가공·FCM 알림      │
│  - 안준환(센서): BLE/RSSI와 vision의 정합성 합의                            │
│  - DEP-FUT-003 후행 진입 시점                                            │
└─────────────────────────────────────────────────────────────────────────┘
```

위 단계는 4월 시점의 잠정 안이며, 2학기 팀 회고에서 변경될 수 있다.

### 3.4 Safety Event Schema (V2 섹션 7 — 합의 가능 후보)

V2 단계에서 김도성의 V2 에이전트가 정리한 후보. §3.1(detection) + §3.2(risk
interpretation)를 backend로 보낼 **단일 페이로드**로 합본한 형태이다.
**정식 등록은 안준환의 `packages/shared_contracts/**`와 협의 후** 진행 (V2 섹션 11
또는 2학기 단계 2 시점). 본 절은 합의용 후보 문서일 뿐이며 현재 등록 위치는 없음.

#### 3.4.1 V2 단계에서 "Safety Event"라는 단위가 필요한 이유

4월 시점 §3.1(detection)과 §3.2(risk interpretation)는 각각 다음 단위였다:

- **detection 응답**: 모델 출력 — 어떤 클래스가 어느 bbox에 어느 score로 검출됨.
- **risk interpretation**: 그 detection을 사용자에게 어떤 위험·안내로 변환할지.

V2 단계에서 통합 흐름을 그릴 때 두 단위를 따로 두면 다음 문제가 발생한다:

```
1. backend가 detection만 받으면 위험 판단을 backend에서 다시 해야 함 → 모델 로직 중복
2. 단말 추론(2학기 단계 2 모바일 단말 후보)이라면 detection 결과를 그대로 backend에
   보내는 것이 비효율적 — 모든 프레임을 보내면 트래픽 폭증
3. risk interpretation을 client(앱)에서 하면 위험 판단 로직이 클라이언트별로 갈림
```

→ **해결**: detection이 일정 위험 임계값을 넘은 경우에만 "Safety Event" 단일 페이로드로
backend에 발생을 보고. backend는 그것을 받아서 FCM 알림 + rideRequests 위험 기록 같은
2차 동작 트리거.

이는 V2_SECTION_PLAN §5 김도성 섹션 7의 명시 목표 ("ai_vision 출력 후보 schema
정리 — backend 호환 가능 형태")와 일치한다.

#### 3.4.2 Safety Event 후보 응답 본문

```json
{
  "eventId": "string (UUID v4, client-generated)",
  "frameId": "string (UUID v4, 본 이벤트가 발생한 프레임 식별자 — §3.1과 동일)",
  "capturedAt": "string (RFC3339)",
  "riskLevel": "info | warn | danger",
  "reason": "string (snake_case 사유 코드)",
  "primaryClass": "string (class_taxonomy.json의 7개 id 중 하나)",
  "detections": [
    {
      "classId": "string",
      "bbox": { "x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0 },
      "score": 0.0
    }
  ],
  "imageSize": { "width": 1920, "height": 1080 },
  "modelInfo": {
    "name": "string",
    "version": "string"
  },
  "message": "string (사용자에게 들려줄/보여줄 안내 문구, 단말이 생성)"
}
```

#### 3.4.3 필드 의미

```txt
- eventId       : 이벤트 식별자. 단말이 생성한 UUID v4. backend가 중복 수신 시
                  멱등성(idempotency) 보장에 사용.
- frameId       : §3.1과 동일. 본 이벤트를 발생시킨 프레임 식별자.
                  detection-level과 event-level을 연결하기 위함.
- capturedAt    : RFC3339. 김도성 BusArrivalsResponse.updatedAt과 같은 형식.
- riskLevel     : 위험도 enum 3종 (info / warn / danger).
- reason        : snake_case 사유 코드. 후보 예시:
                    "approaching_bus", "bus_door_visible", "off_sidewalk",
                    "obstacle_ahead", "tactile_paving_lost"
- primaryClass  : detections 중 본 이벤트의 주 객체 클래스 id. UI가 한 객체만
                  강조 표시할 때 사용.
- detections    : 이벤트 발생 시점의 detection 결과. §3.1 detections와 동일 형식.
                  빈 list 가능(예: "tactile_paving_lost"는 점자블록이 사라진 사건).
- imageSize     : §3.1과 동일.
- modelInfo     : §3.1과 동일.
- message       : 사용자 안내 문구. 단말이 i18n 적용해 만든다.
                  backend는 메시지 콘텐츠를 신뢰하지 않고 reason 기반으로 재가공 가능.
```

#### 3.4.4 계약 강제 사항 (후보)

```txt
- eventId / frameId / capturedAt / riskLevel / reason 은 필수.
- riskLevel 은 enum 3종: info / warn / danger.
- detections 는 빈 list 허용. 단 primaryClass 가 있으면 detections 안에
  같은 classId 가 최소 1개 있어야 함 (cross-field 검증).
- bbox 값은 정규화 [0, 1] 범위.
- detections[].score 는 [0.0, 1.0] 범위.
- additionalProperties: false (계약 외 필드 침투 차단).
```

#### 3.4.5 정식 등록 위치 후보

```txt
packages/shared_contracts/api/vision_safety_event.request.schema.json   (신규, 단말→backend)
packages/shared_contracts/api/vision_safety_event.response.schema.json  (신규, backend→단말 ack)
```

위 등록은 **김도성 단독 결정 금지**. 안준환 `packages/shared_contracts/**` 영역과
겹치므로 협의 후 V2 섹션 11 또는 2학기 단계 2에서 진행.

#### 3.4.6 backend 호환 가능성 분석

본 schema가 현재 backend 구조와 호환 가능한지 사전 확인:

```txt
- backend/api/app/schemas/*.py: 현재 BusArrival, GeofenceCheck, RideRequest 등
  Pydantic 모델 패턴 동일 (StrictApiModel 베이스 + extra="forbid" + Field 제약).
  본 Safety Event 후보도 같은 패턴으로 등록 가능.
- backend/api/app/api/routes/: 현재 /geofence/check, /ride-requests, /bus-info/...
  엔드포인트가 있음. /vision/safety-events 신규 엔드포인트 추가 시 같은 라우터 패턴.
- FCM 알림 시스템: backend가 riskLevel="danger" 이벤트 수신 시 notification 모듈을
  통해 FCM 발송하는 흐름이 자연스럽게 연결됨.
- Firebase RTDB: 본 이벤트는 cache 대상이 아님 (1회성 이벤트라 cache 의미 없음).
  대신 rideRequests/{requestId}/safetyEvents/{eventId} 같은 sub-path에 기록 가능.
```

→ 본 후보는 현재 backend 패턴과 충돌 없이 합의 가능한 상태.

#### 3.4.7 본 절의 위치

본 §3.4 후보 schema는 **V2 섹션 7 산출물** (V2_SECTION_PLAN §5 김도성 섹션 7 명시
"schema 문서 또는 fixture 형태로 합의 가능 상태").

후속 fixture 생성 (mock Safety Event 샘플)은 **V2 섹션 8 (Mock AI Inference Pipeline)**
에서 진행한다. 본 §3.4는 schema 명세만 다루고 fixture는 다음 섹션에서 보강한다.

---

### 3.5 Mock AI Inference Pipeline (V2 섹션 8 산출물)

V2 섹션 7의 §3.4 Safety Event Schema 후보를 따라 **stub-only** mock pipeline을
구현했다. **실제 모델 호출은 일절 하지 않으며**, fixture JSON을 로드해 후속 통합
단계의 출발점으로 제공한다.

#### 3.5.1 산출물

```
ai_vision/pipelines/
├── fixtures/
│   ├── __init__.py
│   └── mock_safety_events.json        ← Safety Event 샘플 4건
└── mock_inference_pipeline.py         ← fixture 로더 + helper API
```

#### 3.5.2 mock fixture 다양성 (4건)

| eventId 끝 | riskLevel | reason | primaryClass | detections 수 |
|---|---|---|---|---|
| 111... | `info` | `bus_stop_recognized` | `bus_stop` | 1 |
| 333... | `warn` | `approaching_bus` | `bus` | 3 (bus + bus_door + bus_stop) |
| 555... | `danger` | `off_sidewalk` | `roadway` | 2 (roadway + sidewalk) |
| 777... | `danger` | `tactile_paving_lost` | `tactile_paving` | **0 (빈 list)** |

다양성 cover:

- `riskLevel` enum 3종 (info / warn / danger) 모두 등장.
- `detections` 단일 / 다중 / **빈 list** 모두 등장 — 점자블록 사라짐 같은 "객체가 안 보이는
  것 자체가 사건" 케이스도 schema로 표현 가능함을 보여준다.
- `primaryClass`는 4건 모두 `class_taxonomy.json` v0.3.0의 7개 학습 클래스 id 중 하나와 정합.
- `bbox` 좌표는 모두 정규화 [0, 1] 범위. `score`도 [0, 1] 범위.
- `imageSize` / `modelInfo` / `message` 모두 §3.4.2 후보 본문 그대로.

#### 3.5.3 호출자 API

```python
from mock_inference_pipeline import (
    get_all_events,            # 4건 모두 반환 (사본)
    get_events_by_risk,        # riskLevel 필터 (enum 3종)
    get_event_by_id,           # eventId 조회 (없으면 None)
    get_fixture_schema_reference,  # 본 fixture가 따르는 schema 위치 문자열
    MockInferenceError,        # fixture 손상/누락 시 raise
)

events = get_all_events()                              # 4건
warn_events = get_events_by_risk("warn")                # 1건
event = get_event_by_id("11111111-1111-4111-8111-111111111111")  # info 이벤트
```

또는 CLI 진입점으로 빠른 검사 가능:

```
python ai_vision/pipelines/mock_inference_pipeline.py
```

#### 3.5.4 후속 통합 단계 출발점 (완료 기준)

본 V2 섹션 8 산출물은 V2_SECTION_PLAN §5 김도성 섹션 8 완료 기준
"**후속 통합 단계 출발점 확보**"를 충족한다. 후속 활용 예:

- **윤현섭 Flutter UI** — 2학기 단계 3 진입 전이라도 본 mock을 사용해 Safety Event를
  음성·진동·시각 UI로 변환하는 통합 흐름을 시뮬레이션 가능.
- **심현석 backend** — `POST /vision/safety-events` 신규 라우터 추가 시 본 mock 4건을
  통합 테스트 입력으로 사용. FCM 알림 발송 + `rideRequests/{requestId}/safetyEvents/
  {eventId}` 기록 흐름 검증.
- **김도성 V2 섹션 10** (mock pipeline 검증) — 본 fixture가 §3.4 schema 계약을
  시나리오 단위로 충족하는지 검증 (다음 섹션 작업).

#### 3.5.5 실제 모델 추론 코드는 본 모듈 범위 밖

본 모듈은 **stub-only**이며 실제 모델 호출은 하지 않는다. 실제 추론 코드는 2학기 단계 1·2
에서 별도 작성 — 본 모듈은 그 시점에 (1) 실제 추론 모듈로 교체되거나, (2) mock 모드용
으로 분리되어 보존될 수 있다 (V2 섹션 5의 BusArrivalsService mock/live 분리 패턴과
같은 의도).

---

---

## 4. 4월 시점 산출물 인덱스

```txt
- ../README.md                     : 김도성 4월 ai_vision 영역 산출물 인덱스
- ../dataset_plan/class_taxonomy.json    : 7개 클래스 정의 + 어노테이션 형식 + 우선순위
- ../dataset_plan/data_collection_guide.md : 환경 분포 / PII 보호 / 양·품질 기준
- ../dataset_plan/labeling_standards.md  : bbox 일반 규칙 / 클래스별 세부 / IAA / 미정 보고
- ../model_research/model_candidates.csv : 4개 후보 정량 표
- ../model_research/model_comparison.md  : 5개 차원 정성 비교 + 4월 결정/유보 분리
- pipelines/README.md (이 파일)    : 향후 통합 위치 메모
```

---

## 5. 책임자·갱신 절차

- 파이프라인 책임자: 김도성 (담당 영역)
- 본 placeholder는 2학기 시작 시점에 정식 모듈로 대체된다.

