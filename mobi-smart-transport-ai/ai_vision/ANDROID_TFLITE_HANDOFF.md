# Android TFLite 연결 인계서

이 문서는 AI 모델을 Flutter/Android 앱에 연결할 때 따라야 할 규칙이다. 앱 화면·카메라
권한·플러그인 선택은 앱 담당 영역이며, AI Vision은 아래 모델 입출력과 결과 해석을
제공한다.

## 1. 전달물

| 항목 | 위치 | 용도 |
| --- | --- | --- |
| 버스 문 TFLite 모델 | `ai_vision/models/yolo11n_bus_door_v1_float32.tflite` | 휴대폰 내 버스·버스 문 탐지 |
| 일반 버스 기준선 | `ai_vision/models/yolo11n_coco_bus_baseline_float32.tflite` | 버스 단일 클래스 비교용 |
| PC 참조 어댑터 | `ai_vision/pipelines/tflite_bus_inference.py` | Android 결과와 비교할 기준 구현 |
| Android 실행 기준 | `ai_vision/pipelines/android_live_profile.json` | 후면 카메라·15 FPS·latest-only 정책 |
| 정지/영상 검증법 | `ai_vision/models/README.md` | 모델과 출력 해석 재검증 |

앱 연동에는 버스 문 TFLite 모델을 사용한다. 이는 `bus`와 `bus_door` 두 클래스를
탐지한다. 일반 버스 기준선은 COCO 사전학습 **bus 단일 모델**이므로, 버스 문 안내에
사용하면 안 된다. 장애물·점자블록은 이 모델의 대상이 아니다.

## 2. 카메라에서 모델까지

```text
후면 카메라 프레임
→ 이전 분석이 끝나지 않았다면 새 프레임 대신 최신 프레임만 유지
→ 비율 유지 letterbox: 640 × 640, 빈 여백 값 114
→ BGR/RGBA를 RGB 순서로 변환
→ float32로 바꾸고 각 값을 255로 나눔 (0.0~1.0)
→ 입력 tensor [1, 640, 640, 3]
→ TFLite 실행
```

권장 카메라 기준은 후면 카메라, 1280×720, 목표 15 FPS다. 단말 성능이 부족하면
카메라 프레임을 모두 처리하려 하지 말고, 추론 중에는 오래된 프레임을 버리고 최신
프레임 하나만 분석한다.

## 3. TFLite 출력 해석

버스 문 모델 출력은 `float32 [1, 6, 8400]`이다.

- 채널 `0~3`: `cx, cy, w, h` — **0~1 정규화 좌표**
- 채널 `4`: 클래스 `0`의 `bus` 신뢰도
- 채널 `5`: 클래스 `1`의 `bus_door` 신뢰도
- 각 클래스 신뢰도 `0.50` 미만: 버린다.
- NMS는 **같은 클래스끼리만** IoU `0.45`로 적용한다. 버스 문은 버스 차체 안에
  있어도 정상이며, 두 클래스를 함께 NMS 처리하면 문 후보가 사라질 수 있다.
- 좌표는 먼저 640을 곱한 뒤, letterbox 여백을 제거하고 원래 카메라 프레임 크기로
  되돌린다. 그 뒤 0~1 정규화 `x, y, w, h`로 변환한다.

중요: 출력 좌표를 처음부터 640 픽셀 좌표라고 가정하면 박스가 잘못 복원돼 탐지가
사라진다. 변환한 버스 문 TFLite 모델을 실제 공개 테스트 이미지에 실행해 `bus 0.940`,
`bus_door 0.892 / 0.798`로 이 규칙을 검증했다.

## 4. 앱이 받아야 할 AI Vision 결과

앱/Context·Audio 담당자에게는 원본 이미지가 아니라 아래와 같은 관측 결과를 넘긴다.

```json
{
  "frameId": "uuid",
  "capturedAt": "RFC3339 UTC timestamp",
  "detections": [
    {
      "classId": "bus",
      "score": 0.92,
      "bbox": { "x": 0.10, "y": 0.21, "w": 0.55, "h": 0.46 }
    }
  ],
  "guidance": {
    "direction": "LEFT | CENTER | RIGHT",
    "relativeDistance": "FAR | MEDIUM | NEAR",
    "motion": "UNKNOWN | APPROACHING | STABLE | RECEDING"
  }
}
```

`motion`은 현재 프레임의 bus 박스 면적을 직전 **분석 완료 프레임**의 bus 박스
면적과 비교한 값이다. 첫 탐지이거나 직전 프레임에 bus가 없으면 `UNKNOWN`이다.
실제 미터 거리나 충돌 위험도를 뜻하지 않는다.

앱은 탐지가 없는 프레임에서 “버스가 없다”는 음성을 매번 출력하면 안 된다. AI Vision의
결과가 비어 있으면 이번 프레임에 신뢰할 만한 안내 후보가 없다는 뜻으로 처리한다.
음성 문구·중복 억제·위험 우선순위는 Context/Audio 담당자가 결정한다.

## 5. 앱 담당자 완료 기준

1. 모델 파일을 Android 앱 asset으로 포함하고 실제 Android 기기에서 interpreter를 연다.
2. 공개 버스 이미지로 `bus` 탐지가 1개 이상 나오는지 확인한다.
3. 입력 tensor와 출력 tensor가 각각 `[1,640,640,3]`, `[1,6,8400]`인지 로그로 확인한다.
4. 공개 테스트 이미지에서 `bus`와 `bus_door`가 각각 하나 이상 나오는지 확인한다.
5. Android 실기기에서 후면 카메라 권한, 세로/가로 회전, 장시간 실행 시 프레임 누적이
   없는지를 확인한다.

에뮬레이터는 1~3의 앱 배포·모델 로딩·출력 형식 확인에만 유효하다. 실제 버스를
카메라로 비춘 인식 성능은 Android 실기기에서 검증해야 한다.

## 6. 담당 경계

- AI Vision: 모델 파일, 전처리·후처리 규칙, 결과 형식, PC 기준선, 검증 데이터 제공
- Flutter/Android 앱 담당: 카메라 권한·preview·asset 등록·프레임 전달·앱 내 TFLite 실행
- Context/Audio 담당: 결과를 실제 음성 문구·공간음향·중복 억제로 변환

모델 또는 출력 규격을 바꾸기 전에는 AI Vision 담당자와 먼저 맞춘다. 추후 장애물 전용
학습 모델이 추가되면 클래스 수·출력 채널·신뢰도 기준이 달라질 수 있다.
