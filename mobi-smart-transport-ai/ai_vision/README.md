# AI Vision - 김도성 담당 영역

2학기 AI 비전 기능을 위한 데이터셋, 모델 리서치, 아키텍처 준비 영역입니다.

4월에는 실제 모델 학습/추론 코드나 Flutter/백엔드 실시간 통합을 구현하지 않습니다.
목표는 데이터 수집 계획, 라벨링 기준, 모델 후보 리서치, 향후 파이프라인 초안 작성입니다.

---

## 1. 4월 산출물 인덱스 (섹션 8 결과)

```txt
ai_vision/
├── README.md                          ← 이 파일 (영역 인덱스)
├── dataset_plan/
│   ├── class_taxonomy.json            ← 7개 클래스 정의 (v0.2) + 어노테이션 형식 + 우선순위
│   ├── data_collection_guide.md       ← 환경 분포 / PII 보호 / 양·품질 기준 / 메타데이터
│   └── labeling_standards.md          ← bbox 규칙 / 클래스별 세부 / IAA / 미정 보고 절차
├── model_research/
│   ├── model_candidates.csv           ← 5개 후보 정량 표 (입력 해상도/COCO mAP/라이선스 포함)
│   └── model_comparison.md            ← 5개 차원 정성 비교 + 4월 결정/유보 분리
└── pipelines/
    └── README.md                       ← 향후 통합 흐름·인터페이스 후보 메모
```

---

## 2. 클래스 정의 요약

`dataset_plan/class_taxonomy.json`의 7개 클래스 (priority 표기):

```txt
high   : bus, bus_door, bus_stop, roadway, tactile_paving
medium : sidewalk, obstacle
```

학습 클래스가 아닌 항목 (개인정보 보호용 블러 처리 대상):

```txt
- person       : 얼굴 블러
- license_plate: 번호판 블러
```

---

## 3. 4월에 결정한 것 / 결정하지 않은 것

### 3.1 4월에 결정한 것

```txt
- 7개 학습 클래스와 우선순위 (taxonomy v0.2)
- 어노테이션 형식: bbox (segmentation은 4월 범위에서 제외)
- PII 보호 정책: 얼굴/번호판 블러, EXIF GPS 제거 (옵션 A)
- 라벨링 일관성 절차: peer review + IAA + 미정 케이스 보고
- 후보 모델 5종의 라이선스·정량 비교 (model_candidates.csv)
```

### 3.2 4월에 결정하지 않은 것 (2학기 결정)

```txt
- 최종 모델 선정 (fine-tuning mAP 결과 없이 결정 위험)
- 추론 위치 (on-device vs backend vs hybrid) — 다른 팀원 협의 필요
- 학습 인프라 (PyTorch vs TensorFlow) — 팀 합의 필요
- detection 결과 표준 응답 schema 등록 — packages/shared_contracts와 협의 필요
- 양자화/pruning 적용 여부 — 프로파일링 결과 필요
```

위 5가지는 **김도성 단독 결정 사항이 아니므로** 본 4월 산출물에서는 의도적으로 결정 보류한다.
2학기 시작 시점에 윤현섭(앱)/심현석(백엔드)/안준환(센서/공통 인프라)와 협의한다.

---

## 4. 다른 팀원 영역과의 경계

본 영역(`ai_vision/`)은 **김도성 4월 담당 두 영역 중 하나**이다 (다른 하나는 `services/public_data/`).

다음은 **김도성이 손대지 않는다**:

```txt
- backend/api/**            : 심현석 (FastAPI 백엔드)
- infrastructure/firebase/**: 심현석 (RTDB / FCM)
- apps/passenger_app/**     : 윤현섭 (Flutter 사용자 앱)
- apps/driver_app/**        : 윤현섭 (Flutter 기사 앱)
- packages/mobile_sensors/**: 안준환 (BLE / RSSI)
- future_modules/head_tracking/**, future_modules/spatial_audio/**: 2학기 범위 (김도성 제외)
- packages/shared_contracts/**: 협의 없이 단독 수정 금지
```

비콘 거리 테스트 계획과 공간음향 방향 테스트 계획은 김도성 4월 범위에서 제외합니다.

---

## 5. 책임자

- 영역 책임자: 김도성
- 본 README는 4월 산출물의 진입점이며, 2학기 시작 시점에 본격 구현 인덱스로 갱신된다.
