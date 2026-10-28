# Android TFLite model artifacts

현재 Android 현장 검증에 사용할 기본 산출물:

```text
yolo11n_unified_bus_obstacle_stop_v3_float32.tflite
```

앱 담당자에게 전달할 정확한 Android 입력·출력 규칙과 검수 기준은
[`../ANDROID_TFLITE_HANDOFF.md`](../ANDROID_TFLITE_HANDOFF.md)에 정리돼 있다.

Create it on a Python 3.12/3.13 environment with TensorFlow installed:

```powershell
python -m pip install -r ai_vision/requirements-tflite-export.txt
python ai_vision/pipelines/export_android_tflite.py
```

이 파일은 `bus`, `bus_door`, `parked_pm`, `pole`, `tree_trunk`, `bus_stop` 여섯 클래스를
탐지하는 통합 현장 검증 모델이다. 정확한 사용 규칙과 평가 한계는
[`../UNIFIED_MODEL_FIELD_TEST_HANDOFF.md`](../UNIFIED_MODEL_FIELD_TEST_HANDOFF.md)를 따른다.

`yolo11n_coco_bus_baseline_float32.tflite`은 Android 연결 자체를 비교 확인하기 위한
COCO `bus` 단일 클래스 기준선이며, 실제 통합 현장 검증 모델로 사용하지 않는다.

Before an app integrator copies a model into Flutter Android assets, verify:

1. The TFLite interpreter opens it on a real Android device.
2. Its input size and output tensor layout match the Android adapter.
3. A known bus image produces a `bus` result consistent with the PC baseline.

## TFLite output-to-guidance validation

`ai_vision/pipelines/tflite_bus_inference.py` is the reference adapter used
before the Android camera is connected. For the current unified model it
accepts `[1, 10, 8400]`, decodes all six classes, applies per-class thresholds
and same-class NMS, restores boxes to the original image size, then creates a
`VisionResult`.

Run the end-to-end check in the Docker export image:

```powershell
docker run --rm --mount type=bind,src=<project-absolute-path>,dst=/workspace `
  -w /workspace --entrypoint python mobi-tflite-export:python312-cpu `
  ai_vision/pipelines/tflite_bus_inference.py `
  --source ai_vision/pipelines/fixtures/external/bus.jpg `
  --model-profile unified-v3 `
  --model ai_vision/models/yolo11n_unified_bus_obstacle_stop_v3_float32.tflite `
  --output .tool-tmp/tflite-unified.vision-guidance.json
```

The result JSON is local evidence only. The Android adapter must use the same
input contract: letterboxed RGB `[1, 640, 640, 3]` `float32` values in
`[0, 1]`, followed by the same bus filtering and NMS policy. This export's
first four output channels are normalized `cx, cy, w, h` values in `[0, 1]`;
multiply them by 640 before removing letterbox padding and restoring original
camera-frame coordinates.

## Video sequence validation

Use the same adapter on a public test video before an Android phone is
available. It samples frames in chronological order and compares each bus box
with the preceding sampled frame, so the result can include `APPROACHING`,
`STABLE`, or `RECEDING`. This is a screen-size estimate only; it is not a
real-world distance measurement.

```powershell
docker run --rm --mount type=bind,src=<project-absolute-path>,dst=/workspace `
  -w /workspace --entrypoint python mobi-tflite-export:python312-cpu `
  ai_vision/pipelines/tflite_bus_inference.py --video `
  --source ai_vision/pipelines/fixtures/external/waiting-for-a-bus.webm `
  --model ai_vision/models/yolo11n_coco_bus_baseline_float32.tflite `
  --frame-stride 30 --max-samples 20 `
  --output .tool-tmp/tflite-waiting-for-a-bus.video-guidance.json
```
