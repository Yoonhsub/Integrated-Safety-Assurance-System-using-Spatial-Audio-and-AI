# AI Hub 국내 세로 장애물 데이터 준비 기록

## 목적

공개 해외 데이터에서 국내 정류장 환경으로 잘 전이되지 않았던 기둥·나무 줄기 모델을
보강하기 위해, AI Hub의 국내 도로 이미지와 BBOX JSON을 YOLO 학습 형식으로 변환한다.

## 원본 라벨과 프로젝트 클래스

원본 JSON의 카테고리 `Column & Tree`에는 나무 줄기와 인공 기둥이 함께 포함된다.
원본에는 둘을 분리할 정보가 없으므로, 이 데이터만으로 `tree_trunk`와
`sidewalk_pole`을 별도 모델 클래스로 만들 수 없다.

이번 데이터셋에서는 다음처럼 하나의 안전 안내 후보로 통합한다.

| 원본 카테고리 | 변환 클래스 | 의미 |
| --- | --- | --- |
| `Column & Tree` | `vertical_obstacle` | 보행 경로 주변의 나무 줄기 또는 인공 기둥 |

따라서 사용자가 받는 안내도 객체의 정확한 재질을 단정하지 않고, “전방에 세로 장애물이
있습니다”처럼 정책 단계에서 표현해야 한다.

## 변환 결과 (2026-10-12)

| 항목 | 결과 |
| --- | ---: |
| 원본 이미지 | 880장 |
| BBOX JSON | 880개 |
| 이미지·JSON 대응 쌍 | 708쌍 |
| 대응 이미지가 없는 JSON | 172개 (자동 제외) |
| 학습 / 검증 / 테스트 | 496 / 106 / 106장 |
| 데이터셋 형식 검사 | 오류 0개 |

원본은 차량 주행 영상의 연속 프레임이므로 파일 번호 순서의 연속 구간을 70/15/15로
나눴다. 무작위 분할보다 거의 같은 장면이 학습과 테스트에 동시에 들어갈 가능성을
줄이는 방법이다.

## 재현 명령

원본 파일은 저장소에 넣지 않는다. AI Hub 이용 약관을 준수해 로컬에서만 읽고,
변환 결과도 `.tool-tmp/`에 둔다.

```powershell
docker run --rm `
  --mount type=bind,src=<프로젝트_절대경로>,dst=/workspace `
  --mount type=bind,src=<바탕화면>,dst=/desktop,readonly `
  --workdir /workspace `
  --entrypoint python `
  mobi-tflite-export:python312-cpu `
  ai_vision/pipelines/prepare_aihub_vertical_obstacle_dataset.py `
  --images /desktop/20201213_14_CCW_in_E_B/images `
  --annotations "/desktop/[라벨]20201213_14_CCW_in_E_B/annotations" `
  --target .tool-tmp/aihub_vertical_obstacle_v1
```

그 다음 아래 검사에서 `images=708, labels=708, errors=0`이 나오면 정상이다.

```powershell
docker run --rm `
  --mount type=bind,src=<프로젝트_절대경로>,dst=/workspace,readonly `
  --workdir /workspace `
  --entrypoint python `
  mobi-tflite-export:python312-cpu `
  ai_vision/pipelines/validate_yolo_dataset.py `
  --dataset-root .tool-tmp/aihub_vertical_obstacle_v1 `
  --class-count 1
```

## 다음 판단

변환만으로 바로 기존 버스·버스 문 모델에 합치지 않는다. `vertical_obstacle` 전용
모델을 별도 학습하고 국내 테스트 장면에서 재현율과 오검출을 검토한 뒤, 안내 후보에
추가할지 결정한다.
