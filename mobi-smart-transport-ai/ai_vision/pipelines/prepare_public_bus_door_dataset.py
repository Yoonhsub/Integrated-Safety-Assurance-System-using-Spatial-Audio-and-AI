"""공개 버스 문 YOLO 데이터를 MOBI의 2개 클래스 기준으로 변환한다.

원본 클래스: Bus(0), Front_door(1), Number(2), Rear_door(3)
목표 클래스: bus(0), bus_door(1)
"""

from __future__ import annotations

import argparse
import shutil
from dataclasses import dataclass
from pathlib import Path


SOURCE_SPLIT_TO_TARGET = {"train": "train", "valid": "val", "test": "test"}
SOURCE_CLASS_TO_TARGET = {0: 0, 1: 1, 3: 1}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}


@dataclass(frozen=True)
class PreparationReport:
    images: int
    kept_labels: int
    removed_number_labels: int


def _convert_label(label_path: Path) -> tuple[list[str], int, int]:
    converted: list[str] = []
    kept = 0
    removed_number = 0
    for line_number, raw_line in enumerate(label_path.read_text(encoding="utf-8").splitlines(), start=1):
        fields = raw_line.split()
        if not fields:
            continue
        if len(fields) != 5:
            raise ValueError(f"{label_path}: line {line_number} must contain 5 YOLO fields")
        try:
            source_class = int(fields[0])
            tuple(float(value) for value in fields[1:])
        except ValueError as exc:
            raise ValueError(f"{label_path}: line {line_number} contains invalid YOLO values") from exc
        target_class = SOURCE_CLASS_TO_TARGET.get(source_class)
        if target_class is None:
            if source_class == 2:
                removed_number += 1
                continue
            raise ValueError(f"{label_path}: line {line_number} has unexpected source class {source_class}")
        converted.append(" ".join([str(target_class), *fields[1:]]))
        kept += 1
    return converted, kept, removed_number


def prepare_dataset(source_root: Path, target_root: Path) -> PreparationReport:
    """원본을 보존하며 새 폴더에 이미지와 변환된 YOLO 라벨을 만든다."""
    if target_root.exists():
        raise FileExistsError(f"target directory already exists: {target_root}")
    image_count = 0
    kept_labels = 0
    removed_number_labels = 0
    for source_split, target_split in SOURCE_SPLIT_TO_TARGET.items():
        images_dir = source_root / source_split / "images"
        labels_dir = source_root / source_split / "labels"
        if not images_dir.is_dir() or not labels_dir.is_dir():
            raise FileNotFoundError(f"source split requires images/ and labels/: {source_split}")
        target_images = target_root / target_split / "images"
        target_labels = target_root / target_split / "labels"
        target_images.mkdir(parents=True)
        target_labels.mkdir(parents=True)
        for image_path in sorted(path for path in images_dir.iterdir() if path.suffix.lower() in IMAGE_EXTENSIONS):
            label_path = labels_dir / f"{image_path.stem}.txt"
            if not label_path.is_file():
                raise FileNotFoundError(f"missing source label for image: {image_path}")
            converted, kept, removed = _convert_label(label_path)
            shutil.copy2(image_path, target_images / image_path.name)
            (target_labels / label_path.name).write_text("\n".join(converted) + ("\n" if converted else ""), encoding="utf-8")
            image_count += 1
            kept_labels += kept
            removed_number_labels += removed
    (target_root / "data.yaml").write_text(
        "train: train/images\nval: val/images\ntest: test/images\nnames:\n  0: bus\n  1: bus_door\n",
        encoding="utf-8",
    )
    return PreparationReport(images=image_count, kept_labels=kept_labels, removed_number_labels=removed_number_labels)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare public bus-door data for MOBI two-class YOLO training.")
    parser.add_argument("--source-root", type=Path, required=True, help="Roboflow YOLO export root")
    parser.add_argument("--target-root", type=Path, required=True, help="New output directory; must not exist")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    report = prepare_dataset(args.source_root, args.target_root)
    print(f"prepared images={report.images}, keptLabels={report.kept_labels}, removedNumberLabels={report.removed_number_labels}")


if __name__ == "__main__":
    main()
