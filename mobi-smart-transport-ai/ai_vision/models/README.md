# Android TFLite model artifacts

Expected first artifact:

```text
yolo11n_coco_bus_baseline_float32.tflite
```

Create it on a Python 3.12/3.13 environment with TensorFlow installed:

```powershell
python -m pip install -r ai_vision/requirements-tflite-export.txt
python ai_vision/pipelines/export_android_tflite.py
```

This first file is a **COCO pretrained baseline**. It is suitable only for
validating that Android can detect the generic COCO `bus` class. It does not
detect `bus_door`, `bus_stop`, tactile paving, or project-specific obstacles.
Those require a separately trained model and a new export.

Before an app integrator copies a model into Flutter Android assets, verify:

1. The TFLite interpreter opens it on a real Android device.
2. Its input size and output tensor layout match the Android adapter.
3. A known bus image produces a `bus` result consistent with the PC baseline.

## TFLite output-to-guidance validation

`ai_vision/pipelines/tflite_bus_inference.py` is the reference adapter used
before the Android camera is connected. It accepts the model output
`[1, 84, 8400]`, selects COCO class `5` (`bus`), removes overlapping boxes,
restores the box to the original image size, and creates `VisionResult` plus
the proposed guidance handoff.

Run the end-to-end check in the Docker export image:

```powershell
docker run --rm --mount type=bind,src=<project-absolute-path>,dst=/workspace `
  -w /workspace --entrypoint python mobi-tflite-export:python312-cpu `
  ai_vision/pipelines/tflite_bus_inference.py `
  --source ai_vision/pipelines/fixtures/external/bus.jpg `
  --model ai_vision/models/yolo11n_coco_bus_baseline_float32.tflite `
  --output .tool-tmp/tflite-bus.vision-guidance.json
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
