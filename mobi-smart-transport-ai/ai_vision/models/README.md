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
