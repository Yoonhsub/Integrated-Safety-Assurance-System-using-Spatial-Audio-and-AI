"""커스텀 YOLO 데이터셋의 구조와 bbox 형식을 학습 전 검증한다."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
SPLITS = ("train", "val", "test")


@dataclass(frozen=True)
class DatasetValidationReport:
    image_count: int
    label_count: int
    errors: tuple[str, ...]

    @property
    def valid(self) -> bool:
        return not self.errors


def load_class_names(taxonomy_path: Path) -> list[str]:
    """공식 taxonomy 배열 순서에서 YOLO 클래스 이름을 읽는다."""
    try:
        payload = json.loads(taxonomy_path.read_text(encoding="utf-8"))
        names = [entry["id"] for entry in payload["classes"]]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise ValueError(f"unable to read class taxonomy: {taxonomy_path}") from exc
    if not names or len(names) != len(set(names)):
        raise ValueError("taxonomy must contain unique class ids")
    return names


def _validate_label_file(label_path: Path, *, class_count: int) -> list[str]:
    errors: list[str] = []
    for line_number, raw_line in enumerate(label_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) != 5:
            errors.append(f"{label_path}: line {line_number} must contain 5 YOLO fields")
            continue
        try:
            class_id = int(fields[0])
            x_center, y_center, width, height = (float(value) for value in fields[1:])
        except ValueError:
            errors.append(f"{label_path}: line {line_number} contains non-numeric values")
            continue
        if not 0 <= class_id < class_count:
            errors.append(f"{label_path}: line {line_number} class id {class_id} is outside taxonomy")
        if not (0.0 <= x_center <= 1.0 and 0.0 <= y_center <= 1.0 and 0.0 < width <= 1.0 and 0.0 < height <= 1.0):
            errors.append(f"{label_path}: line {line_number} bbox must be normalized with positive width and height")
    return errors


def validate_dataset(
    dataset_root: Path,
    *,
    taxonomy_path: Path | None = None,
    class_count: int | None = None,
) -> DatasetValidationReport:
    """YOLO 분할 폴더와 모든 이미지·라벨 조합을 검사한다."""
    if taxonomy_path is not None and class_count is not None:
        raise ValueError("supply either taxonomy_path or class_count, not both")
    if class_count is None:
        if taxonomy_path is None:
            raise ValueError("taxonomy_path or class_count is required")
        class_count = len(load_class_names(taxonomy_path))
    if class_count <= 0:
        raise ValueError("class_count must be positive")
    image_count = 0
    label_count = 0
    errors: list[str] = []
    for split in SPLITS:
        images_dir = dataset_root / split / "images"
        labels_dir = dataset_root / split / "labels"
        if not images_dir.is_dir() or not labels_dir.is_dir():
            errors.append(f"{split} split must contain images/ and labels/ directories")
            continue
        images = sorted(path for path in images_dir.iterdir() if path.suffix.lower() in IMAGE_EXTENSIONS)
        image_count += len(images)
        for image_path in images:
            label_path = labels_dir / f"{image_path.stem}.txt"
            if not label_path.is_file():
                errors.append(f"missing label for image: {image_path}")
                continue
            label_count += 1
            errors.extend(_validate_label_file(label_path, class_count=class_count))
        for label_path in labels_dir.glob("*.txt"):
            if not any(image_path.stem == label_path.stem for image_path in images):
                errors.append(f"label has no matching image: {label_path}")
    return DatasetValidationReport(image_count=image_count, label_count=label_count, errors=tuple(errors))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate a custom YOLO dataset before training.")
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--taxonomy", type=Path, default=None, help="Project taxonomy JSON (default: 7-class taxonomy)")
    parser.add_argument("--class-count", type=int, default=None, help="Class count for a dedicated model")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    taxonomy_path = args.taxonomy
    if taxonomy_path is None and args.class_count is None:
        taxonomy_path = Path("ai_vision/dataset_plan/class_taxonomy.json")
    report = validate_dataset(args.dataset_root, taxonomy_path=taxonomy_path, class_count=args.class_count)
    print(f"images={report.image_count}, labels={report.label_count}, errors={len(report.errors)}")
    for error in report.errors:
        print(f"- {error}")
    if not report.valid:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
