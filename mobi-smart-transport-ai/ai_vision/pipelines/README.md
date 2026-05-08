# AI Vision Pipeline Placeholder

이 폴더는 2학기 본격 구현 시 AI 비전 추론 파이프라인이 들어갈 예정 위치이다.
**4월에는 실제 학습/추론 코드를 구현하지 않는다.**

---

## 1. 향후 추론 흐름 (2학기)

```txt
Camera Frame
→ Pre-process (resize/normalize)
→ Object Detection Model (YOLO계열 또는 EfficientDet-Lite)
→ Bus / Bus Door / Bus Stop / Roadway / Sidewalk / Obstacle / Tactile Paving 탐지
→ Risk Interpretation (사용자 위치 + 검출 객체 → 위험도/안내 메시지)
→ Voice / Vibration / FCM 알림 출력
```

위 흐름의 객체 분류 7종은 `../dataset_plan/class_taxonomy.json`에서 정의한다.

---

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

