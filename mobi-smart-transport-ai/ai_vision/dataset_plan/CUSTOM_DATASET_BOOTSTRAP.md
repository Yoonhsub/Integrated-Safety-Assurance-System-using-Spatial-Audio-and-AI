# 커스텀 학습 데이터셋 시작 안내

현재 TFLite 기준선 모델은 일반 `bus`만 탐지한다. 개발 일정에서 요구하는 `bus_door`와
전방 장애물 안내를 하려면, 아래 7개 클래스로 직접 수집·라벨링한 데이터로 새 모델을
학습해야 한다.

```text
0 bus             1 bus_door        2 bus_stop
3 roadway         4 sidewalk        5 obstacle
6 tactile_paving
```

클래스 번호는 [`custom_bus_safety_dataset.yaml`](custom_bus_safety_dataset.yaml)과
`class_taxonomy.json`의 순서를 절대 바꾸지 않는다. 번호가 바뀌면 모델은 예를 들어
`bus_door`를 `bus_stop`으로 잘못 해석한다.

## 1. 이번 주 최소 목표

아직 실제 Android 기기가 없어도 데이터셋 준비는 가능하다. 첫 목표는 대규모 학습이
아닌 **작은 시범 데이터셋 100장**과 라벨 품질 확인이다.

| 우선순위 | 클래스 | 최소 라벨 수 | 이유 |
| --- | --- | ---: | --- |
| 1 | obstacle | 50 | 개발 일정의 주요 레벨, 전방 위험 안내의 핵심 |
| 2 | bus | 50 | 기존 기준선과 비교할 기준 |
| 2 | bus_door | 50 | 탑승 가능 위치 안내의 핵심 |
| 3 | bus_stop / tactile_paving | 각 20 | 정류장·보행 보조 확인 |
| 4 | roadway / sidewalk | 각 20 | bbox 기반 시범 검증 |

한 이미지에 여러 객체를 라벨링할 수 있으므로 이미지 100장으로 시작할 수 있다. 이
단계의 목적은 성능 수치가 아니라, 사진·라벨 규칙·개인정보 처리 절차가 실제로 잘
작동하는지 확인하는 것이다.

## 2. 폴더 구조

아래 폴더는 **로컬 또는 팀 비공개 저장소**에 만든다. 얼굴·번호판 등이 포함될 수 있는
원본 이미지와 대용량 데이터셋은 GitHub에 올리지 않는다.

```text
data/custom_bus_safety_v1/
├── train/
│   ├── images/
│   └── labels/
├── val/
│   ├── images/
│   └── labels/
├── test/
│   ├── images/
│   └── labels/
└── metadata.csv
```

처음 100장을 확보했다면 `train/val/test = 70/15/15`로 나눈다. 같은 짧은 영상에서
뽑은 연속 프레임은 반드시 한 분할에만 둔다. 그렇지 않으면 거의 같은 장면이 학습과
테스트에 동시에 들어가 성능이 과장된다.

## 3. 수집·개인정보 처리 순서

1. 버스 정류장·보도 환경을 후면 카메라로 촬영한다. 버스 문은 측면에서 식별 가능하게
   촬영하고, 열림·닫힘 모두 수집한다.
2. 초점이 흐리거나 클래스가 전혀 없는 사진을 제외한다.
3. 사람 얼굴, 차량 번호판, 불필요한 개인 식별 문구를 블러 처리하고 EXIF GPS를 제거한다.
4. `metadata.csv`에 수집 조건을 기록한다.
5. Label Studio, CVAT, LabelImg 중 팀이 고른 도구로 YOLO bbox 라벨을 만든다.
6. 아래 검증 명령을 통과한 데이터만 학습 후보로 사용한다.

라벨 bbox 기준은 기존 [labeling_standards.md](labeling_standards.md)를 따른다.
특히 `bus_door`는 `bus` 박스 내부에 중첩해서 라벨링하며, 사람·자전거는 `obstacle`로
라벨링하지 않는다.

## 4. metadata.csv 형식

아래 헤더를 사용한다. `image_id`는 파일명에서 확장자를 뺀 값과 같게 두면 추적이 쉽다.

```csv
image_id,split,captured_at,time_of_day_bucket,stop_type,camera_height_bucket,distance_bucket,city,weather,pii_blur_done,gps_anon_done,collector_name,license
cheongju_0001,train,2026-10-07T15:30:00+09:00,day_clear,shelter,170cm,near,cheongju,clear,true,true,team_member,internal_only
```

## 5. 자동 검증

데이터를 배치한 뒤 아래 명령을 실행한다.

```powershell
python ai_vision/pipelines/validate_yolo_dataset.py `
  --dataset-root data/custom_bus_safety_v1 `
  --taxonomy ai_vision/dataset_plan/class_taxonomy.json
```

검증기는 다음 오류를 막는다.

- `train/val/test` 폴더 누락
- 이미지에 대응하는 라벨 파일 누락
- 잘못된 클래스 번호
- YOLO 라벨의 형식 오류 또는 0~1 범위 밖 좌표
- 폭·높이가 0인 bbox

검증 통과는 라벨이 **형식상** 유효하다는 의미일 뿐, 객체를 맞게 그렸다는 의미는 아니다.
시범 50장은 반드시 두 명이 독립 라벨링해 IAA를 확인한다.

## 6. 다음 전환 기준

시범 데이터셋에서 다음을 만족하면 본격 수집·학습으로 넘어간다.

- 개인정보 처리와 메타데이터가 빠진 사진이 없음
- `bus_door`, `obstacle` 라벨 규칙에 대한 모호 사례를 팀에서 합의함
- 50장 이중 라벨 IAA가 클래스별 0.7 이상
- 학습/검증/테스트 분할에 동일 연속 장면이 섞이지 않음

그 다음에야 YOLO 학습, 평가, TFLite 재변환 순서로 진행한다. 현재 COCO 버스 기준선은
새 모델 성능을 비교하는 용도로 유지한다.

## 공개 버스 문 데이터의 별도 처리

Roboflow에서 내려받은 공개 버스 문 데이터는 원본 클래스가 `Bus`, `Front_door`,
`Number`, `Rear_door`로 구성되어 있다. 이 데이터만으로는 7개 전체 클래스를 학습할 수
없다. 첫 실험에서는 `Number`를 제외하고 앞문·뒷문을 `bus_door` 하나로 합친 2개 클래스
모델을 만든다.

```powershell
python ai_vision/pipelines/prepare_public_bus_door_dataset.py `
  --source-root <Roboflow-YOLO-압축해제-폴더> `
  --target-root data/public_bus_door_v1
```

그 결과는 `public_bus_door_dataset.yaml`을 사용해 학습한다. `obstacle` 등 나머지
클래스는 국내 직접 촬영·라벨링 데이터를 확보한 뒤 별도 확장 모델에서 추가한다.
