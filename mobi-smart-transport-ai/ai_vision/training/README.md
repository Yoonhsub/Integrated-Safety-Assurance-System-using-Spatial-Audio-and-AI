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

The first custom-training data-preparation baseline is a separate three-class
subset: `bus`, `bus_door`, and `bus_stop`, with IDs 0–2 in
`class_mapping_3class.json` and `datasets/bus_safety_3class.yaml`. It does not
replace the four-class setup or remove `obstacle` from the project taxonomy.
Select the mapping explicitly when validating it:

```powershell
python scripts/validate_ai_vision_dataset.py `
  --data ai_vision/training/datasets/bus_safety_3class.yaml `
  --mapping ai_vision/training/class_mapping_3class.json
```

## Review-gated source conversion

`scripts/prepare_ai_vision_dataset.py` reads AI-Hub CVAT XML/images and the
Roboflow YOLO export directly from ZIP files; it does not extract or modify the
source archives. A normal invocation is a read-only dry run:

```powershell
python scripts/prepare_ai_vision_dataset.py `
  --aihub-zip C:\path\to\Bbox_1_new.zip `
  --roboflow-zip C:\path\to\bus-open-door-v2-yolov8.zip
```

Review queues are created only when `--write-review-dir` is explicitly passed.
The tool writes separate `box_review.csv` and `image_review.csv` files. Every
box and image starts `unreviewed`; no parser or preview can approve data. The
image row is a separate completeness attestation covering all three target
classes in the full image, including checking for missing `bus` labels in
Roboflow frames and missing `bus_door` labels in AI-Hub frames. Each candidate
box needs an explicit decision (`approved`, `needs_correction`, `rejected`,
`uncertain`, or `unreviewed`). Corrected coordinates are written in
`corrected_bbox`; source annotation coordinates remain untouched. Source group
identity must be reviewed and marked `verified` with a nonempty reason before
conversion. Image completeness decisions also require a reason; non-approval box
decisions require a `review_reason`. The tool rejects stale review rows and
prevents an `approved` row from silently changing source coordinates. Unknown
license/provenance is recorded as `not_recorded_in_this_manifest`, not inferred.

Creating review manifests computes SHA-256 for every source image so review
decisions stay bound to the inspected bytes; this explicit operation can take
time on the large AI-Hub archive. A missing hash blocks conversion. Preview
generation also requires an explicit output path and selected box IDs:

```powershell
python scripts/prepare_ai_vision_dataset.py `
  --roboflow-zip C:\path\to\bus-open-door-v2-yolov8.zip `
  --preview-dir C:\path\to\review-previews `
  --box-id "<box-id-from-box_review.csv>"
```

For objects absent from source annotations (for example a missing bus box in a
Roboflow door image), use an explicit, image-scoped workbench selection:

```powershell
python scripts/prepare_ai_vision_dataset.py `
  --roboflow-zip C:\path\to\bus-open-door-v2-yolov8.zip `
  --workbench-dir C:\path\outside\the-repository\bus-review `
  --image-id "<image-id-from-image_review.csv>"
```

The generated `index.html` lets a reviewer draw new pixel-coordinate boxes
over copied review images and exports `additional_annotations.csv`. The source
ZIP and existing `box_review.csv` are not edited. Every exported new box is
`unreviewed`; a human must explicitly set `review_status=approved`, provide a
reviewer, ISO-8601 `reviewed_at`, and a review reason, and preserve the source
hash and image dimensions. `review_reason` should explain each decision and
must describe corrections, rejection, or uncertainty. New IDs use an
image-specific `additional:` namespace and cannot collide with source box IDs.
Coordinates are `xyxy_pixel` by default; bounded
`xyxy_normalized` is also accepted. New boxes must be at least 16 pixels wide
and high.

Pass the sidecar with both existing review manifests to include it in dry-run
gating or explicit conversion:

```powershell
python scripts/prepare_ai_vision_dataset.py `
  --roboflow-zip C:\path\to\bus-open-door-v2-yolov8.zip `
  --box-review-csv C:\path\to\box_review.csv `
  --image-review-csv C:\path\to\image_review.csv `
  --additional-annotations-csv C:\path\to\additional_annotations.csv
```

To scope the operation to the external 75-image batch, also pass its
`sample_index.csv` with `--image-ids-csv`. This filters the parsed source list
before review gating, so unreviewed images outside that explicit sample do not
enter the sample conversion queue. Unknown or duplicate IDs are rejected.

Unreviewed, uncertain, or correction-pending new boxes block their image.
Rejected boxes are excluded, and image completeness still requires a separate
human decision. Approved new boxes merge with approved/corrected source boxes
only when the image is explicitly marked `complete` with a reason and its
source group is verified. The workbench cannot approve boxes or attest image
completeness; a person must check all three target classes in the full frame.
The existing four-class mapping and seven-class taxonomy are unchanged.

Only explicit `--apply` can copy images and generate labels. It requires both
review CSVs, an output directory, and a positive `--max-images` cap. All images
must have human-reviewed annotation completeness, all candidate boxes must be
approved/corrected/rejected, and each source group must be verified. At least
three verified groups are required; whole groups are deterministically assigned
to train/val/test. Source groups that cannot be tied to a known capture session
must remain unverified. Roboflow train-split variants are kept train-only;
the source split is not used as a trustworthy evaluation split. The generated
dataset includes paired image/label folders, `dataset_manifest.csv`, a local
`dataset.yaml`, and is checked with the existing validator and the explicit
three-class mapping. Start with a small cap and inspect the resulting manifest
before increasing it. This workflow does not merge datasets, download data,
train a model, or make a runtime model change.

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
