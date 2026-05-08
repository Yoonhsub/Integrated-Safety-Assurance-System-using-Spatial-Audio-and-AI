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

### 3.1 detection 결과 표준 응답 (예시 — 미정)

```json
{
  "frameId": "string (UUID)",
  "capturedAt": "string (RFC3339)",
  "detections": [
    {
      "classId": "bus | bus_door | bus_stop | roadway | sidewalk | obstacle | tactile_paving",
      "bbox": { "x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0 },
      "score": 0.0
    }
  ]
}
```

위 모양은 후보일 뿐이다. 정식 등록 위치 후보:

```txt
packages/shared_contracts/api/vision_detection.response.schema.json   (신규)
```

이 schema 등록은 **김도성 단독 결정 금지** — 안준환의 `packages/shared_contracts/**`
영역과 겹치므로 협의 후 등록.

### 3.2 risk interpretation 출력 (예시 — 미정)

검출 결과를 백엔드/Flutter가 음성·진동·FCM 알림으로 변환하는 단계에서 추가 표준이
필요할 수 있다. 4월 시점에는 형식 결정하지 않음.

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

