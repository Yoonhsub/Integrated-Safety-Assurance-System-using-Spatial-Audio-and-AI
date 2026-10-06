# AI Vision custom YOLO training

This package prepares and evaluates project-specific YOLO weights. It does not
change the current runtime provider or promote a trained model automatically.

## Scope and class subset

The project taxonomy remains the source of the full seven classes. The first
bbox detector trains only `bus`, `bus_door`, `bus_stop`, and `obstacle`:
these are instance-like objects that can be boxed in one image and serve bus
recognition, boarding-location, stop-recognition, and pedestrian-path
observation use cases. `roadway`, `sidewalk`, and `tactile_paving` describe
large or continuous surface regions. Their extent and boundary are poorly
represented by independent object boxes; keep them in the taxonomy and consider
a later segmentation/scene-understanding task after the detection benchmark.
The current taxonomy labels still describe the broader project policy; this
training subset is not a taxonomy edit.
Taxonomy `detection_threshold` values are inference confidence policy, not
training-label filters or dataset inclusion rules. Keep all reviewed annotations
for the selected classes and tune runtime thresholds only after evaluation.

YOLO labels use contiguous IDs 0–3. The canonical mapping from those IDs to
project taxonomy IDs is `class_mapping.json`; `datasets/bus_safety.yaml` contains
Ultralytics' required duplicate class-name declaration. Tests and the dataset
validator reject disagreement between the two files and the project taxonomy.

## Dataset preparation and annotation

Prepare authorized images locally at:

```text
ai_vision/datasets/custom_bus_safety/
  images/{train,val,test}/
  labels/{train,val,test}/
```

Every image needs a same-stem YOLO `.txt` file. A zero-byte label file means a
reviewed negative image; a missing label is an error. Follow
[`ANNOTATION_GUIDELINES.md`](ANNOTATION_GUIDELINES.md) and the existing
[`dataset_plan/labeling_standards.md`](../dataset_plan/labeling_standards.md).
Do not collect/download images through these scripts. Remove EXIF GPS and blur
faces and license plates before sharing data.

Split by recording/session first, then location/scene when sessions are not
available. Never randomly distribute adjacent frames from the same recording
across train/validation/test. Optionally add `dataset_manifest.csv` to the
dataset root with columns `image,split,source_group`; `image` is relative to the
dataset root. The validator rejects a source group assigned to multiple splits.
The validator also flags byte-identical image files across splits. A recording
or scene identifier should be non-identifying and stable across all frames.

## Validate, train, evaluate

Install the already-declared AI Vision dependencies in the project environment:

```powershell
python -m pip install -r ai_vision/requirements.txt
```

Validate the dataset before training:

```powershell
python scripts/validate_ai_vision_dataset.py --data ai_vision/training/datasets/bus_safety.yaml
```

Run training explicitly. CPU is the default; pass an Ultralytics device value
such as `0` only when a compatible CUDA GPU is available:

```powershell
python scripts/train_ai_vision_yolo.py `
  --data ai_vision/training/datasets/bus_safety.yaml `
  --model yolo11n.pt `
  --epochs 100 --imgsz 640 --batch 16 --device cpu `
  --project ai_vision/training/runs --name bus-safety-yolo11n
```

When this explicit command is run, Ultralytics may resolve/download its named
pretrained model if it is not present locally. The CLI does not train or
download anything on import or `--help`. Training arguments, seed, data YAML
hash, model identifier, and Ultralytics version are saved with the run.

Evaluate a completed local weight file on the held-out test split:

```powershell
python scripts/evaluate_ai_vision_yolo.py `
  --model ai_vision/training/runs/bus-safety-yolo11n/weights/best.pt `
  --data ai_vision/training/datasets/bus_safety.yaml `
  --split test --device cpu
```

The evaluation report includes mAP50, mAP50–95, precision, recall, and per-class
precision/recall/AP. Test data should only be used for final evaluation, not
repeated tuning.

## Acceptance and model promotion

Do not accept a model from one aggregate mAP score alone. Review per-class
precision and recall, especially `bus_door` and `bus_stop` recall; inspect
`obstacle` false positives and false negatives in real bus-stop scenes; check
confusion with generic signs/vehicles and background; and review missed or
incorrectly localized objects. Compare validation and held-out test results,
inspect representative prediction images, and record the dataset/model
versions. Set numeric acceptance thresholds only after the first representative
benchmark and team review; this repository does not invent them in advance.

Model weights, source images, and run outputs are local artifacts and are not
committed. Reviewed label text is allowed only when sharing its source dataset
is authorized. A trained model is not the runtime/default model until a separate
promotion change validates its compatibility and explicitly updates
`YOLOVisionProvider`/taxonomy mapping with regression tests.
