# 모바일 경량 비전 모델 후보 비교

이 문서는 MOBI 프로젝트 2학기 AI 비전 기능에 사용할 모바일 경량 모델 후보를
정성·정량 비교하여, **4월 단계에서 결정 가능한 부분**과 **2학기로 미루는 결정**을 분리한다.

`model_candidates.csv`는 정량 표(라이선스/입력 해상도/COCO mAP 등)이고, 본 문서는
그 표를 보완하는 비교/근거이다.

---

## 1. 후보 모델 정리

후보는 모두 **모바일 추론 가능** 조건을 만족한다 (TFLite 또는 ONNX 변환 가능).

| 후보 | 패밀리 | 입력 해상도 | COCO mAP@0.5:0.95 | 라이선스 | 추론 위치 후보 |
|---|---|---|---|---|---|
| YOLOv8n | YOLO | 640 | 37.3 | AGPL-3.0 | on-device 또는 backend |
| YOLOv11n | YOLO | 640 | 39.5 | AGPL-3.0 | on-device 또는 backend |
| EfficientDet-Lite0 | EfficientDet | 320 | (참고치, 클래스/도메인별 상이) | Apache 2.0 | on-device |
| EfficientDet-Lite1 | EfficientDet | 384 | (Lite0보다 약간 상승) | Apache 2.0 | on-device |
| MobileNetV2 | MobileNet | 224 | 분류용 — detection 단독 불가 | Apache 2.0 | on-device |

> **출처 근거**: YOLOv8n/YOLOv11n의 mAP는 Ultralytics 공식 문서. EfficientDet-Lite와 MobileNetV2는
> 분류/탐지 카테고리가 달라 직접 비교하지 않으며, TFLite 공식 모바일 모델 목록을 근거로 한다.
> mAP 수치는 **COCO 80 클래스 일반 모델** 기준이며 — MOBI 프로젝트의 7개 커스텀 클래스 학습 결과는
> 데이터셋 빌드 후 별도 평가가 필요하다.

---

## 2. 비교 차원

각 후보를 다음 5개 차원으로 평가한다.

### 2.1 정확도 (COCO baseline)

```txt
1순위 YOLOv11n (39.5)  >  2순위 YOLOv8n (37.3)  >  EfficientDet-Lite0/1 (도메인 의존)
```

단 MOBI의 7개 클래스는 COCO와 일부만 겹친다 (`bus`만 직접 겹침). 따라서 **사전학습 모델로서의
일반 정확도**는 참고만 하고, 최종 결정은 fine-tuning 결과를 보고 한다.

### 2.2 모델 크기·속도

```txt
가장 가벼움: EfficientDet-Lite0 (≈ 4 MB, 320 입력)
중간       : YOLOv8n / YOLOv11n (≈ 6 MB, 640 입력)
가장 느림  : EfficientDet-Lite1 (≈ 7 MB, 384 입력)
```

YOLO는 입력이 640이라 픽셀 수는 많지만, anchor-free 단일 stage라 추론 자체는 빠름.
EfficientDet-Lite0은 입력 320으로 가장 가벼우나 **작은 객체 탐지 약점**이 있다.
점자블록·먼 표지판 같은 작은 객체가 포함된 MOBI 7개 클래스에는 입력 해상도가 크리티컬하다.

### 2.3 라이선스

```txt
상업화·서비스화 안전     : EfficientDet-Lite0/1, MobileNetV2 (Apache 2.0)
학생/연구 OK, 상업화 별도: YOLOv8n, YOLOv11n (AGPL-3.0)
```

캡스톤 결과물은 **학교 평가용**이므로 AGPL-3.0이 직접 문제는 아니다. 단 향후 외부 서비스화
시점에 YOLO를 그대로 쓰면 별도 Ultralytics Enterprise 라이선스 협의가 필요하다.
이 사실을 **2학기 의사결정 자료**에 명시해 두는 것이 본 비교의 목적 중 하나.

### 2.4 학습 인프라

```txt
PyTorch 친화: YOLOv8n, YOLOv11n
TensorFlow 친화: EfficientDet-Lite, MobileNetV2
```

팀의 학습 인프라가 PyTorch 중심이면 YOLO 계열이, TensorFlow 중심이면 EfficientDet-Lite가
부담이 작다. 4월 시점에 팀 인프라가 확정되지 않았으므로 본 결정은 2학기로 미룬다.

### 2.5 모바일 추론 통합 난이도

```txt
- TFLite: Flutter `tflite_flutter`, MediaPipe 직접 통합 가능 (가장 안정적)
- ONNX:   `onnxruntime` Flutter 플러그인 사용 가능하나 platform 별 빌드 변동 큼
```

YOLO 계열은 둘 다 export 가능하지만 EfficientDet-Lite는 TFLite 네이티브이라 통합 비용이
가장 적다.

---

## 3. 4월 단계에서 결정 가능한 것

다음은 **4월 단계의 데이터·라이선스만으로** 의사결정 가능한 항목이다.

```txt
1. 학생 캡스톤 시연 단계까지는 YOLOv8n / YOLOv11n / EfficientDet-Lite0 셋 모두 사용 가능 (라이선스 OK).
2. 외부 서비스화 가능성을 미리 차단하고 싶으면 EfficientDet-Lite0 / MobileNet 계열을 우선.
3. 추론 위치는 4월 결정하지 않는다 — 2학기 통합 시 윤현섭(앱)·심현석(백엔드)·안준환(센서)과 협의.
4. 본 4개 후보 외 신규 모델(예: 2학기 시점에 출시될 더 새로운 nano 변형)은 2학기 시작 시점에
   재평가 — 본 문서를 그대로 단정 자료로 쓰지 말 것.
```

---

## 4. 4월 단계에서 결정하지 않는 것 (의도적 보류)

```txt
- 최종 모델 선정. fine-tuning mAP 결과 없이 결정하면 위험.
- 추론 위치 (on-device vs backend). 다른 팀원 산출물 의존이라 김도성 단독 결정 불가.
- 학습 인프라 선택 (PyTorch vs TensorFlow). 팀 협의 필요.
- 데이터 augmentation 정책. 데이터셋 빌드 시작 후 결정.
- INT8 양자화 / pruning 적용 여부. 프로파일링 결과를 보고 결정.
```

---

## 5. 2학기 의사결정 흐름 제안

```txt
1. 데이터셋 빌드 (data_collection_guide.md 기준)
2. 학습 인프라 결정 (팀 인프라/프레임워크 합의)
3. 1차 후보 2개 선정 → fine-tuning → mAP 비교
4. 모바일 추론 프로파일링 (실제 디바이스에서 fps/메모리)
5. 최종 1개 선정 → INT8 양자화 → Flutter 통합
```

위 흐름은 4월 시점의 제안이며, 2학기 시작 시점에 팀 회고를 거쳐 조정한다.

---

## 6. 책임자·갱신 절차

- 모델 리서치 책임자: 김도성 (담당 영역)
- 본 문서는 4월 산출물로서 2학기 시작 시점에 1차 갱신될 예정.

| 버전 | 날짜 | 변경 요약 |
|---|---|---|
| 0.1.0 | 2026-04 (4월 섹션 8) | 초안 — 4개 후보 5개 차원 비교, 4월 결정/유보 분리 |
