"""Roboflow 정류장·킥보드 YOLO export를 하나의 시범 데이터셋으로 합친다.

정류장 export의 클래스는 ``bus_stop, parked_pm, sidewalk_pole, trash_bin,
tree_trunk``이고, 킥보드 export의 ``kickboard``는 ``parked_pm``으로 바꾼다.
``trash_bin``은 현재 한 개 bbox뿐이어서 학습 대상에서 제외한다.
"""

from __future__ import annotations

import argparse
import shutil
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


SPLITS = {"train": "train", "valid": "val", "test": "test"}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
# source class -> pilot class: bus_stop, sidewalk_pole, tree_trunk, parked_pm
BUS_STOP_CLASS_MAP = {0: 0, 1: 3, 2: 1, 4: 2}
KICKBOARD_CLASS_MAP = {0: 3}
CLASS_NAMES = ("bus_stop", "sidewalk_pole", "tree_trunk", "parked_pm")


@dataclass(frozen=True)
class PreparationReport:
    images: int
    labels_per_class: dict[int, int]
    dropped_trash_bin_labels: int


def _to_detection_fields(label_path: Path, line_number: int, fields: list[str]) -> list[str]:
    """Roboflow detection/segmentation export를 YOLO detection bbox로 정규화한다."""
    if len(fields) == 5:
        try:
            tuple(float(value) for value in fields[1:])
        except ValueError as exc:
            raise ValueError(f"{label_path}: line {line_number} contains invalid YOLO values") from exc
        return fields[1:]
    if len(fields) < 7 or (len(fields) - 1) % 2:
        raise ValueError(f"{label_path}: line {line_number} is not YOLO detection or segmentation data")
    try:
        points = [float(value) for value in fields[1:]]
    except ValueError as exc:
        raise ValueError(f"{label_path}: line {line_number} contains invalid YOLO values") from exc
    xs, ys = points[::2], points[1::2]
    left, right = min(xs), max(xs)
    top, bottom = min(ys), max(ys)
    return [str((left + right) / 2), str((top + bottom) / 2), str(right - left), str(bottom - top)]


def _convert_label(label_path: Path, class_map: dict[int, int]) -> tuple[list[str], int]:
    converted: list[str] = []
    dropped = 0
    for line_number, raw_line in enumerate(label_path.read_text(encoding="utf-8").splitlines(), start=1):
        fields = raw_line.split()
        if not fields:
            continue
        try:
            source_class = int(fields[0])
        except ValueError as exc:
            raise ValueError(f"{label_path}: line {line_number} has an invalid class id") from exc
        bbox_fields = _to_detection_fields(label_path, line_number, fields)
        target_class = class_map.get(source_class)
        if target_class is None:
            dropped += 1
            continue
        converted.append(" ".join([str(target_class), *bbox_fields]))
    return converted, dropped


def _copy_source(
    source_root: Path,
    target_root: Path,
    prefix: str,
    class_map: dict[int, int],
    label_counts: Counter[int],
) -> tuple[int, int]:
    image_count = 0
    dropped = 0
    for source_split, target_split in SPLITS.items():
        images_dir = source_root / source_split / "images"
        labels_dir = source_root / source_split / "labels"
        if not images_dir.is_dir() or not labels_dir.is_dir():
            raise FileNotFoundError(f"source split requires images/ and labels/: {source_split}")
        target_images = target_root / target_split / "images"
        target_labels = target_root / target_split / "labels"
        target_images.mkdir(parents=True, exist_ok=True)
        target_labels.mkdir(parents=True, exist_ok=True)
        for image_path in sorted(path for path in images_dir.iterdir() if path.suffix.lower() in IMAGE_EXTENSIONS):
            label_path = labels_dir / f"{image_path.stem}.txt"
            if not label_path.is_file():
                raise FileNotFoundError(f"missing source label for image: {image_path}")
            converted, removed = _convert_label(label_path, class_map)
            target_name = f"{prefix}_{image_path.name}"
            target_label = target_labels / f"{Path(target_name).stem}.txt"
            shutil.copy2(image_path, target_images / target_name)
            target_label.write_text("\n".join(converted) + ("\n" if converted else ""), encoding="utf-8")
            label_counts.update(int(line.split()[0]) for line in converted)
            image_count += 1
            dropped += removed
    return image_count, dropped


def prepare_dataset(bus_stop_root: Path, kickboard_root: Path, target_root: Path) -> PreparationReport:
    """원본 export를 보존하고 새 4클래스 YOLO 데이터셋을 만든다."""
    if target_root.exists():
        raise FileExistsError(f"target directory already exists: {target_root}")
    label_counts: Counter[int] = Counter()
    bus_stop_images, dropped = _copy_source(
        bus_stop_root, target_root, "busstop", BUS_STOP_CLASS_MAP, label_counts
    )
    kickboard_images, _ = _copy_source(
        kickboard_root, target_root, "kickboard", KICKBOARD_CLASS_MAP, label_counts
    )
    (target_root / "data.yaml").write_text(
        "train: train/images\nval: val/images\ntest: test/images\nnames:\n"
        + "".join(f"  {index}: {name}\n" for index, name in enumerate(CLASS_NAMES)),
        encoding="utf-8",
    )
    return PreparationReport(
        images=bus_stop_images + kickboard_images,
        labels_per_class=dict(sorted(label_counts.items())),
        dropped_trash_bin_labels=dropped,
    )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare the bus-stop obstacle pilot dataset.")
    parser.add_argument("--bus-stop-root", type=Path, required=True)
    parser.add_argument("--kickboard-root", type=Path, required=True)
    parser.add_argument("--target-root", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    report = prepare_dataset(args.bus_stop_root, args.kickboard_root, args.target_root)
    print(
        f"prepared images={report.images}, labelsPerClass={report.labels_per_class}, "
        f"droppedTrashBinLabels={report.dropped_trash_bin_labels}"
    )


if __name__ == "__main__":
    main()
