"""AI Hub BBOX JSON을 ``vertical_obstacle`` YOLO 데이터셋으로 변환한다.

AI Hub의 ``Column & Tree``는 나무 줄기와 인공 기둥을 하나의 카테고리로 제공한다.
이 도구는 원본 이미지·JSON을 수정하지 않고, 파일명이 실제로 일치하는 쌍만 복사한다.
연속 촬영 프레임의 누수를 줄이기 위해 파일 번호 순서의 연속 구간으로 train/val/test를
나눈다. 따라서 같은 장면의 이웃 프레임이 무작위로 서로 다른 split에 섞이지 않는다.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


TARGET_CATEGORY = "Column & Tree"
TARGET_CLASS_NAME = "vertical_obstacle"
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}


@dataclass(frozen=True)
class ImageAnnotations:
    image_path: Path
    width: int
    height: int
    boxes: tuple[tuple[float, float, float, float], ...]


def _read_matching_annotation(json_path: Path, image_root: Path, *, min_width: float, min_height: float) -> ImageAnnotations | None:
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    image = payload["images"]
    image_path = image_root / image["file_name"]
    if not image_path.is_file():
        return None
    width, height = int(image["width"]), int(image["height"])
    if width <= 0 or height <= 0:
        raise ValueError(f"image dimensions must be positive: {json_path}")

    category_names = {int(item["id"]): str(item["name"]) for item in payload["categories"]}
    boxes: list[tuple[float, float, float, float]] = []
    for annotation in payload["annotations"]:
        if category_names.get(int(annotation["category_id"])) != TARGET_CATEGORY:
            continue
        x, y, box_width, box_height = (float(value) for value in annotation["bbox"])
        if not all(math.isfinite(value) for value in (x, y, box_width, box_height)):
            continue
        left, top = max(0.0, x), max(0.0, y)
        right, bottom = min(float(width), x + box_width), min(float(height), y + box_height)
        clipped_width, clipped_height = right - left, bottom - top
        if clipped_width < min_width or clipped_height < min_height:
            continue
        if clipped_width <= 0.0 or clipped_height <= 0.0:
            continue
        boxes.append((left, top, clipped_width, clipped_height))
    return ImageAnnotations(image_path=image_path, width=width, height=height, boxes=tuple(boxes))


def collect_matching_annotations(image_root: Path, annotation_root: Path, *, min_width: float = 0.0, min_height: float = 0.0) -> tuple[list[ImageAnnotations], int]:
    """이미지 파일이 존재하는 BBOX JSON만 읽고, 누락된 쌍 수를 함께 반환한다."""
    if not image_root.is_dir() or not annotation_root.is_dir():
        raise FileNotFoundError("image_root and annotation_root must be directories")
    if min_width < 0 or min_height < 0:
        raise ValueError("minimum bbox dimensions must not be negative")
    records: list[ImageAnnotations] = []
    missing_images = 0
    for json_path in sorted(annotation_root.glob("*_BBOX.json")):
        record = _read_matching_annotation(json_path, image_root, min_width=min_width, min_height=min_height)
        if record is None:
            missing_images += 1
        else:
            records.append(record)
    return records, missing_images


def _split_records(records: list[ImageAnnotations]) -> dict[str, list[ImageAnnotations]]:
    """파일 번호 순서의 연속 구간으로 70/15/15 split을 만든다."""
    ordered = sorted(records, key=lambda item: item.image_path.name)
    train_end = round(len(ordered) * 0.70)
    val_end = train_end + round(len(ordered) * 0.15)
    return {"train": ordered[:train_end], "val": ordered[train_end:val_end], "test": ordered[val_end:]}


def _to_yolo_lines(record: ImageAnnotations) -> list[str]:
    lines = []
    for x, y, width, height in record.boxes:
        x_center = (x + width / 2) / record.width
        y_center = (y + height / 2) / record.height
        lines.append(f"0 {x_center:.8f} {y_center:.8f} {width / record.width:.8f} {height / record.height:.8f}")
    return lines


def prepare_dataset(image_root: Path, annotation_root: Path, target_root: Path, *, min_width: float = 0.0, min_height: float = 0.0) -> dict[str, int]:
    """대응 이미지·BBOX JSON을 단일 ``vertical_obstacle`` YOLO 데이터셋으로 만든다."""
    if target_root.exists():
        raise FileExistsError(f"target directory already exists: {target_root}")
    records, missing_images = collect_matching_annotations(
        image_root, annotation_root, min_width=min_width, min_height=min_height
    )
    if not records:
        raise ValueError("no matching image and BBOX JSON pairs found")

    report: Counter[str] = Counter(missing_json_images=missing_images)
    for split, split_records in _split_records(records).items():
        images_dir, labels_dir = target_root / split / "images", target_root / split / "labels"
        images_dir.mkdir(parents=True, exist_ok=True)
        labels_dir.mkdir(parents=True, exist_ok=True)
        for record in split_records:
            shutil.copy2(record.image_path, images_dir / record.image_path.name)
            (labels_dir / f"{record.image_path.stem}.txt").write_text(
                "\n".join(_to_yolo_lines(record)) + ("\n" if record.boxes else ""), encoding="utf-8"
            )
            report[f"{split}_images"] += 1
            report[f"{split}_labels"] += len(record.boxes)
    (target_root / "data.yaml").write_text(
        "train: train/images\nval: val/images\ntest: test/images\nnames:\n  0: vertical_obstacle\n",
        encoding="utf-8",
    )
    return dict(report)


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert AI Hub Column & Tree BBOX JSON to a YOLO dataset.")
    parser.add_argument("--images", type=Path, required=True, help="AI Hub images directory")
    parser.add_argument("--annotations", type=Path, required=True, help="AI Hub annotations directory")
    parser.add_argument("--target", type=Path, required=True, help="new YOLO dataset directory")
    parser.add_argument("--min-width", type=float, default=0.0, help="skip bbox narrower than this original-image pixel value")
    parser.add_argument("--min-height", type=float, default=0.0, help="skip bbox shorter than this original-image pixel value")
    args = parser.parse_args()
    print(
        prepare_dataset(
            args.images, args.annotations, args.target, min_width=args.min_width, min_height=args.min_height
        )
    )


if __name__ == "__main__":
    main()
