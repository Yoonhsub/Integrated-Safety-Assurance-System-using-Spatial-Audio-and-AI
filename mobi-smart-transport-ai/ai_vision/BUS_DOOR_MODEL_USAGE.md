# 버스 문 모델 사용 방법

## 1. 무엇을 받는가

`ai_vision/models/yolo11n_bus_door_v1.pt`는 버스와 버스 문을 구분하도록 학습한
YOLO 모델이다.

| 클래스 번호 | 클래스 이름 | 의미 |
| ---: | --- | --- |
| `0` | `bus` | 버스 차량 전체 |
| `1` | `bus_door` | 승·하차 문 |

이 파일은 Android 앱에 바로 넣는 형식이 아니라, 학습 결과를 보관·검토하고 Android용
TFLite 파일을 만드는 원본 가중치다.

## 2. 팀원이 모델 파일 받기

모델은 Git LFS로 관리한다. 처음 한 번만 Git LFS를 설치·초기화한다.

```powershell
git lfs install
```

그 다음 기능 브랜치를 받고 LFS 파일까지 내려받는다.

```powershell
git pull origin feature/add-tflite-baseline
git lfs pull
```

아래 파일이 약 5.5MB 크기로 존재하면 정상이다.

```text
ai_vision/models/yolo11n_bus_door_v1.pt
```

파일이 수십~수백 바이트라면 LFS 포인터만 받은 것이므로 `git lfs pull`을 다시 실행한다.

## 3. PC에서 이미지 한 장 확인하기

Python과 Ultralytics가 준비된 환경에서 아래처럼 실행한다.

```python
from ultralytics import YOLO

model = YOLO("ai_vision/models/yolo11n_bus_door_v1.pt")
results = model("test_bus_image.jpg", conf=0.25)
results[0].save(filename="bus-door-result.jpg")
```

결과 이미지에서 `bus`와 `bus_door` 박스가 각각 표시되는지 확인한다. 이 단계는
학습 결과를 PC에서 확인하는 용도이며, 실제 모바일 사용 검증은 아니다.

프로젝트 안내 후보 JSON까지 함께 확인하려면 Docker에서 다음처럼 실행한다.

```powershell
docker run --rm `
  --mount type=bind,src=<프로젝트_절대경로>,dst=/workspace `
  --workdir /workspace `
  --entrypoint python `
  mobi-tflite-export:python312-cpu `
  ai_vision/pipelines/offline_yolo_inference.py `
  --source <버스_이미지_경로> `
  --model ai_vision/models/yolo11n_bus_door_v1.pt `
  --model-name yolo11n-bus-door `
  --model-version public-bus-door-v1 `
  --output .tool-tmp/bus-door.vision-result.json `
  --guidance-output .tool-tmp/bus-door.guidance.json
```

`bus-door.guidance.json`에는 버스 후보와, 버스 차체 안에 충분히 포함된 버스 문 후보가
함께 기록된다. 문 후보의 방향은 문 bbox를 사용하며, 화면상 거리·접근 상태는 버스
차체 bbox를 사용한다.

## 4. Android 연동 단계: TFLite 변환

개발 일정의 Android 카메라 연동 단계에서만 아래 작업을 수행한다. Docker Desktop이
켜진 상태에서 프로젝트 루트에서 실행한다.

```powershell
docker run --rm `
  --mount type=bind,src=<프로젝트_절대경로>,dst=/workspace `
  --workdir /workspace `
  --entrypoint python `
  mobi-tflite-export:python312-cpu `
  ai_vision/pipelines/export_android_tflite.py `
  --source ai_vision/models/yolo11n_bus_door_v1.pt `
  --output ai_vision/models/yolo11n_bus_door_v1_float32.tflite
```

`<프로젝트_절대경로>`에는 `mobi-smart-transport-ai` 폴더의 전체 경로를 넣는다.
예시는 다음과 같다.

```text
C:\ClaudeTest\claude-project\cap-Project\tflite-publish\mobi-smart-transport-ai
```

## 5. Android 담당자가 해야 할 일

1. 생성된 `.tflite` 파일을 Android 앱 assets에 넣는다.
2. 카메라 프레임을 모델 입력 크기와 형식에 맞춰 변환한다.
3. 모델 출력에서 클래스 `0`은 `bus`, 클래스 `1`은 `bus_door`로 해석한다.
4. `bus_door` 박스의 화면상 위치를 AI Vision 쪽 안내 이벤트에 전달한다.
5. 실제 Android 기기에서 버스·버스 문·문이 아닌 창문을 구분하는지 확인한다.

## 6. 기존 COCO 버스 모델과 혼동하지 않기

기존 `yolo11n_coco_bus_baseline_float32.tflite`는 COCO의 일반 `bus`만 감지하는
기준선이다. 이 버스 문 모델은 별도 변환 후 사용해야 하며, 기존 모델을 파일명만
바꿔 교체하면 안 된다. 기존 Android 해석기는 COCO의 `bus` 클래스 번호 `5`를
가정하므로, 버스 문 모델용으로 클래스 번호와 출력 형태를 별도 확인·수정해야 한다.
