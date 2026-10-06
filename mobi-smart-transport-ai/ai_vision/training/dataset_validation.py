"""Validation helpers for the project's Ultralytics detection datasets."""
from __future__ import annotations

import csv
import hashlib
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from pathlib import PurePosixPath
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATA_YAML = PROJECT_ROOT / "ai_vision/training/datasets/bus_safety.yaml"
DEFAULT_MAPPING = PROJECT_ROOT / "ai_vision/training/class_mapping.json"
DEFAULT_TAXONOMY = PROJECT_ROOT / "ai_vision/dataset_plan/class_taxonomy.json"
SPLITS = ("train", "val", "test")
IMAGE_SUFFIXES = {".bmp", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}


@dataclass(frozen=True)
class TrainingClass:
    yolo_id: int
    taxonomy_id: str
    name: str


@dataclass(frozen=True)
class ValidationIssue:
    level: str
    message: str


@dataclass
class DatasetReport:
    split_images: dict[str, int] = field(default_factory=lambda: {s: 0 for s in SPLITS})
    split_labels: dict[str, int] = field(default_factory=lambda: {s: 0 for s in SPLITS})
    class_counts: dict[str, int] = field(default_factory=dict)
    issues: list[ValidationIssue] = field(default_factory=list)

    @property
    def total_images(self) -> int:
        return sum(self.split_images.values())

    @property
    def total_labels(self) -> int:
        return sum(self.split_labels.values())

    @property
    def errors(self) -> list[ValidationIssue]:
        return [issue for issue in self.issues if issue.level == "ERROR"]

    @property
    def warnings(self) -> list[ValidationIssue]:
        return [issue for issue in self.issues if issue.level == "WARNING"]

    def add_error(self, message: str) -> None:
        self.issues.append(ValidationIssue("ERROR", message))

    def add_warning(self, message: str) -> None:
        self.issues.append(ValidationIssue("WARNING", message))


def load_yaml(path: Path) -> dict[str, Any]:
    """Load a YAML mapping without importing the Ultralytics runtime."""
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError(
            "PyYAML is required to read the YOLO dataset configuration. "
            "Install the AI Vision dependencies from ai_vision/requirements.txt."
        ) from exc
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise ValueError(f"Could not read dataset YAML {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"Dataset YAML must contain a mapping: {path}")
    return value


def load_training_classes(
    mapping_path: Path = DEFAULT_MAPPING,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
) -> tuple[TrainingClass, ...]:
    """Load the ordered YOLO subset and ensure it refers to the project taxonomy."""
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    taxonomy = json.loads(taxonomy_path.read_text(encoding="utf-8"))
    taxonomy_classes = {item["id"]: item for item in taxonomy["classes"]}
    raw_classes = mapping.get("classes")
    if not isinstance(raw_classes, list) or not raw_classes:
        raise ValueError("Training class mapping must contain a non-empty classes list.")

    classes: list[TrainingClass] = []
    seen_taxonomy_ids: set[str] = set()
    for expected_id, item in enumerate(raw_classes):
        if not isinstance(item, dict):
            raise ValueError(f"Training class at index {expected_id} must be an object.")
        yolo_id = item.get("yoloId")
        taxonomy_id = item.get("taxonomyId")
        name = item.get("name")
        if yolo_id != expected_id:
            raise ValueError("YOLO class IDs must be contiguous and ordered from zero.")
        if not isinstance(taxonomy_id, str) or taxonomy_id not in taxonomy_classes:
            raise ValueError(f"Unknown project taxonomy class ID: {taxonomy_id!r}.")
        if not isinstance(name, str) or not name:
            raise ValueError(f"Missing YOLO training name for class {taxonomy_id!r}.")
        if name != taxonomy_id:
            raise ValueError(
                f"YOLO training name {name!r} must match its project taxonomy ID {taxonomy_id!r}."
            )
        if taxonomy_id in seen_taxonomy_ids:
            raise ValueError(f"Project taxonomy class is mapped more than once: {taxonomy_id!r}.")
        seen_taxonomy_ids.add(taxonomy_id)
        classes.append(TrainingClass(yolo_id, taxonomy_id, name))
    return tuple(classes)


def _normalize_names(raw_names: Any) -> list[str]:
    if isinstance(raw_names, list):
        return raw_names
    if isinstance(raw_names, dict):
        try:
            indexed = {int(key): value for key, value in raw_names.items()}
        except (TypeError, ValueError) as exc:
            raise ValueError("Dataset YAML names keys must be integer class IDs.") from exc
        if sorted(indexed) != list(range(len(indexed))):
            raise ValueError("Dataset YAML names IDs must be contiguous and ordered from zero.")
        return [indexed[index] for index in range(len(indexed))]
    raise ValueError("Dataset YAML must define names as a list or integer-keyed mapping.")


def validate_dataset_config(
    data_yaml: Path,
    *,
    mapping_path: Path = DEFAULT_MAPPING,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
) -> tuple[dict[str, Any], Path, tuple[TrainingClass, ...]]:
    """Read YAML and ensure its class IDs/names match the canonical subset."""
    config = load_yaml(data_yaml)
    classes = load_training_classes(mapping_path, taxonomy_path)
    names = _normalize_names(config.get("names"))
    expected_names = [item.name for item in classes]
    if names != expected_names:
        raise ValueError(
            f"Dataset YAML names {names!r} do not match class_mapping.json "
            f"{expected_names!r}."
        )
    dataset_path = Path(config.get("path", "."))
    if not dataset_path.is_absolute():
        dataset_path = data_yaml.resolve().parent / dataset_path
    return config, dataset_path.resolve(), classes


def parse_label_text(text: str, class_count: int, *, source: str = "label") -> list[int]:
    """Validate YOLO detection rows and return the class IDs in the file."""
    class_ids: list[int] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 5:
            raise ValueError(
                f"{source}:{line_number}: expected 5 YOLO detection values, got {len(fields)}."
            )
        try:
            class_number = float(fields[0])
            coordinates = [float(value) for value in fields[1:]]
        except ValueError as exc:
            raise ValueError(f"{source}:{line_number}: values must be numeric.") from exc
        if not math.isfinite(class_number) or not class_number.is_integer():
            raise ValueError(f"{source}:{line_number}: class ID must be an integer.")
        class_id = int(class_number)
        if class_id < 0 or class_id >= class_count:
            raise ValueError(
                f"{source}:{line_number}: class ID {class_id} is outside 0..{class_count - 1}."
            )
        if not all(math.isfinite(value) for value in coordinates):
            raise ValueError(f"{source}:{line_number}: bbox values must be finite numbers.")
        x_center, y_center, width, height = coordinates
        if not (0 <= x_center <= 1 and 0 <= y_center <= 1):
            raise ValueError(f"{source}:{line_number}: bbox center must be normalized to [0, 1].")
        if not (0 < width <= 1 and 0 < height <= 1):
            raise ValueError(f"{source}:{line_number}: bbox width and height must be in (0, 1].")
        if (
            x_center - width / 2 < -1e-9
            or x_center + width / 2 > 1 + 1e-9
            or y_center - height / 2 < -1e-9
            or y_center + height / 2 > 1 + 1e-9
        ):
            raise ValueError(f"{source}:{line_number}: bbox extends outside image bounds [0, 1].")
        class_ids.append(class_id)
    return class_ids


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_source_manifest(dataset_root: Path, report: DatasetReport) -> None:
    manifest_path = dataset_root / "dataset_manifest.csv"
    if not manifest_path.exists():
        report.add_warning(
            "dataset_manifest.csv is absent; recording/session leakage cannot be checked."
        )
        return
    groups: dict[str, set[str]] = {}
    covered_images: set[str] = set()
    try:
        with manifest_path.open(encoding="utf-8-sig", newline="") as stream:
            reader = csv.DictReader(stream)
            required_columns = {"image", "split", "source_group"}
            if not reader.fieldnames or not required_columns.issubset(reader.fieldnames):
                report.add_error(
                    "dataset_manifest.csv must have image,split,source_group columns."
                )
                return
            for row_number, row in enumerate(reader, start=2):
                image = (row.get("image") or "").strip().replace("\\", "/")
                image_parts = PurePosixPath(image).parts
                split = (row.get("split") or "").strip()
                group = (row.get("source_group") or "").strip()
                if not image or not group or split not in SPLITS:
                    report.add_error(
                        f"dataset_manifest.csv:{row_number}: image, source_group, and a valid split are required."
                    )
                    continue
                image_path = (dataset_root / image).resolve()
                if not image_path.is_relative_to(dataset_root.resolve()):
                    report.add_error(
                        f"dataset_manifest.csv:{row_number}: image path escapes the dataset root."
                    )
                    continue
                if not image_path.is_file():
                    report.add_error(
                        f"dataset_manifest.csv:{row_number}: image does not exist: {image}."
                    )
                elif len(image_parts) < 3 or image_parts[0] != "images" or image_parts[1] != split:
                    report.add_error(
                        f"dataset_manifest.csv:{row_number}: image path does not match split {split!r}."
                    )
                if image in covered_images:
                    report.add_error(
                        f"dataset_manifest.csv:{row_number}: image is listed more than once: {image}."
                    )
                covered_images.add(image)
                groups.setdefault(group, set()).add(split)
    except OSError as exc:
        report.add_error(f"Could not read dataset_manifest.csv: {exc}")
        return
    for group, splits in sorted(groups.items()):
        if len(splits) > 1:
            report.add_error(
                f"Source group {group!r} leaks across dataset splits: {', '.join(sorted(splits))}."
            )
    for image_dir in (dataset_root / "images" / split for split in SPLITS):
        if image_dir.is_dir():
            for image in image_dir.iterdir():
                if image.is_file() and image.suffix.lower() in IMAGE_SUFFIXES:
                    relative = image.relative_to(dataset_root).as_posix()
                    if relative not in covered_images:
                        report.add_error(
                            f"dataset_manifest.csv has no source group for image: {relative}."
                        )


def validate_dataset(
    data_yaml: Path = DEFAULT_DATA_YAML,
    *,
    mapping_path: Path = DEFAULT_MAPPING,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
) -> DatasetReport:
    """Inspect images, paired labels, split leakage, and class distribution."""
    report = DatasetReport()
    try:
        config, dataset_root, classes = validate_dataset_config(
            data_yaml, mapping_path=mapping_path, taxonomy_path=taxonomy_path
        )
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, json.JSONDecodeError) as exc:
        report.add_error(str(exc))
        return report
    report.class_counts = {item.name: 0 for item in classes}

    seen_names: dict[str, str] = {}
    seen_hashes: dict[str, str] = {}
    for split in SPLITS:
        split_value = config.get(split)
        if not isinstance(split_value, str) or not split_value.strip():
            report.add_error(f"Dataset YAML must define a non-empty {split!r} image path.")
            continue
        image_dir = (dataset_root / split_value).resolve()
        if not image_dir.is_relative_to(dataset_root):
            report.add_error(f"Dataset {split} image path escapes dataset root: {split_value!r}.")
            continue
        if not image_dir.is_dir():
            report.add_error(f"Missing {split} image directory: {image_dir}.")
            continue
        normalized_images = split_value.replace("\\", "/").split("/")
        if len(normalized_images) < 2 or normalized_images[0] != "images":
            report.add_error(f"Dataset {split} path must be under images/: {split_value!r}.")
            continue
        label_relative = Path("labels", *normalized_images[1:])
        label_dir = dataset_root / label_relative
        if not label_dir.is_dir():
            report.add_error(f"Missing {split} label directory: {label_dir}.")
            continue

        images = sorted(
            path for path in image_dir.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
        )
        labels = sorted(label_dir.glob("*.txt"))
        image_stems: dict[str, Path] = {}
        label_stems: dict[str, Path] = {}
        for image in images:
            stem_key = image.stem.casefold()
            if stem_key in image_stems:
                report.add_error(f"Duplicate image file stem in {split}: {image_stems[stem_key].name}, {image.name}.")
            image_stems[stem_key] = image
        for label in labels:
            stem_key = label.stem.casefold()
            if stem_key in label_stems:
                report.add_error(f"Duplicate label file stem in {split}: {label_stems[stem_key].name}, {label.name}.")
            label_stems[stem_key] = label

        report.split_images[split] = len(images)
        for image in images:
            stem_key = image.stem.casefold()
            prior_split = seen_names.get(stem_key)
            if prior_split and prior_split != split:
                report.add_error(f"Image stem {image.stem!r} occurs in both {prior_split} and {split}.")
            seen_names[stem_key] = split
            try:
                digest = _sha256(image)
                prior_image = seen_hashes.get(digest)
                if prior_image and not prior_image.startswith(f"{split}:"):
                    report.add_error(f"Byte-identical images occur across splits: {prior_image} and {split}:{image.name}.")
                seen_hashes[digest] = f"{split}:{image.name}"
            except OSError as exc:
                report.add_error(f"Could not read image {image}: {exc}")
            if stem_key not in label_stems:
                report.add_error(f"Missing label file for image {split}/{image.name}.")

        image_keys = set(image_stems)
        for label_key, label in label_stems.items():
            if label_key not in image_keys:
                report.add_error(f"Orphan label file in {split}: {label.name}.")
                continue
            try:
                class_ids = parse_label_text(
                    label.read_text(encoding="utf-8-sig"),
                    len(classes),
                    source=f"{split}/{label.name}",
                )
            except (OSError, ValueError) as exc:
                report.add_error(str(exc))
                continue
            report.split_labels[split] += len(class_ids)
            for class_id in class_ids:
                report.class_counts[classes[class_id].name] += 1
        if not images:
            report.add_warning(f"The {split} split contains no images.")

    _validate_source_manifest(dataset_root, report)
    return report
