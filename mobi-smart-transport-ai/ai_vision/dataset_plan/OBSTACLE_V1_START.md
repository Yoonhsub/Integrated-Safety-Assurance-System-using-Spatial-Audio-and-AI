# 장애물 탐지 V1 시작 안내

## 목표

개발 일정의 주요 레벨인 전방 `obstacle`을 먼저 검증한다. 이 단계는 버스 정류장 문맥과
보행 중 부딪힐 수 있는 정적 대상을 함께 찾는 4개 클래스 파일럿이다. `bus_stop`은
문맥 정보이고, 나머지는 앱에 전달할 때 `obstacle` 계약으로 통합한다.

## 무엇을 찍고 라벨링하나

| 모델 클래스 | 포함 대상 | 라벨링 방법 |
| --- | --- | --- |
| `bus_stop` | 쉘터 또는 쉘터 없는 정류장의 표지판·기둥 | 정류장 전체를 하나의 bbox로 표시 |
| `sidewalk_pole` | 보도 가까운 정류장·속도제한 표지판 등 인공 기둥 | 표지판과 지지 기둥을 하나의 bbox로 표시 |
| `tree_trunk` | 보행 공간 가까운 나무 줄기 | 잎·가지가 아닌 줄기 부분을 bbox로 표시 |
| `parked_pm` | 정지 상태의 전동킥보드·자전거 | 세워진 상태와 넘어진 상태를 모두 bbox로 표시 |

사람이 타고 이동 중인 전동킥보드·자전거, 사람, 오토바이, 차량, 공사 가림막과
라바콘은 이번 모델에서 제외한다. 지정 주차구역에 정리돼 보행로를 막지 않는 PM도
제외한다. 사람 얼굴·차량 번호판이 찍혔다면 반드시 블러 처리한다.

## 이번 시범 수집 목표

처음에는 사진 **100장**으로 시작한다. 같은 장면을 연속으로 찍었다면 한 분할에만
넣는다. 한 사진에 여러 대상이 있을 수 있으므로 아래 bbox 목표를 모두 만족하는지
확인한다.

| 클래스 | 최소 bbox 목표 |
| --- | ---: |
| `bus_stop` | 50개 |
| `sidewalk_pole` | 30개 |
| `tree_trunk` | 50개 |
| `parked_pm` | 50개 |

| 분할 | 사진 목표 | 용도 |
| --- | ---: | --- |
| `train` | 70장 | 모델 학습 |
| `val` | 15장 | 학습 중 성능 확인 |
| `test` | 15장 | 마지막 성능 확인 |

낮·흐림·역광, 가까움·중간 거리, 왼쪽·가운데·오른쪽 위치를 섞는다. `parked_pm`은
세워진 모습과 넘어진 모습을 모두 수집한다. 안내는 검출 자체가 아니라 화면상
가까우면서 진행 방향에 있을 때만 후속 Context/Audio 모듈이 결정한다.

## 폴더와 라벨 형식

원본 사진과 라벨은 GitHub에 올리지 않고 아래 로컬 폴더에 둔다.

```text
ai_vision/datasets/obstacle_v1/
├── train/images/   ├── train/labels/
├── val/images/     ├── val/labels/
└── test/images/    └── test/labels/
```

YOLO 라벨의 첫 숫자는 아래 모델 클래스 번호다.

```text
0 bus_stop
1 sidewalk_pole
2 tree_trunk
3 parked_pm
```

예: 사진 가운데의 나무 줄기는 `2 0.50 0.55 0.20 0.40`처럼 작성한다. 클래스별
상세 규칙은 [obstacle_v1_class_mapping.json](obstacle_v1_class_mapping.json)과
[labeling_standards.md](labeling_standards.md)의 `obstacle` 항목을 함께 따른다.

## 학습 전 확인

사진을 넣고 라벨링을 마치면 아래 명령을 실행한다. 이 명령은 장애물 전용 모델이
4개 클래스(`0`~`3`)만 사용했는지와 사진·라벨 짝이 맞는지를 검사한다.

```powershell
python ai_vision/pipelines/validate_yolo_dataset.py `
  --dataset-root ai_vision/datasets/obstacle_v1 `
  --class-count 4
```

오류가 0개여야 다음 단계인 YOLO 학습으로 넘어간다.
