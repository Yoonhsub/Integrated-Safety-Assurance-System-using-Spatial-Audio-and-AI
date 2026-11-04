"""공개 pole 학습 데이터와 국내 정류장 테스트 데이터를 분리해 준비한다."""

from __future__ import annotations

import argparse
import shutil
from collections import Counter
from pathlib import Path

from prepare_bus_stop_obstacle_dataset import IMAGE_EXTENSIONS, _convert_label


def _copy_split(source_root: Path, source_split: str, target_root: Path, target_split: str, prefix: str, class_map: dict[int, int], counts: Counter[int]) -> int:
    images_dir = source_root / source_split / "images"
    labels_dir = source_root / source_split / "labels"
    target_images = target_root / target_split / "images"
    target_labels = target_root / target_split / "labels"
    if not images_dir.is_dir() or not labels_dir.is_dir():
        raise FileNotFoundError(f"source split requires images/ and labels/: {source_split}")
    target_images.mkdir(parents=True, exist_ok=True)
    target_labels.mkdir(parents=True, exist_ok=True)
    image_count = 0
    for image_path in sorted(path for path in images_dir.iterdir() if path.suffix.lower() in IMAGE_EXTENSIONS):
        label_path = labels_dir / f"{image_path.stem}.txt"
        if not label_path.is_file():
            raise FileNotFoundError(f"missing source label for image: {image_path}")
        labels, _ = _convert_label(label_path, class_map)
        target_name = f"{prefix}_{image_path.name}"
        shutil.copy2(image_path, target_images / target_name)
        (target_labels / f"{Path(target_name).stem}.txt").write_text("\n".join(labels) + ("\n" if labels else ""), encoding="utf-8")
        counts.update(int(label.split()[0]) for label in labels)
        image_count += 1
    return image_count


def prepare_dataset(
    public_root: Path,
    korean_root: Path,
    target_root: Path,
    *,
    public_class_ids: tuple[int, ...] = (1, 2),
    korean_class_id: int = 2,
    class_name: str = "sidewalk_pole",
) -> dict[str, int]:
    """공개 데이터는 train/val, 국내 정류장 데이터는 전부 test로 유지한다."""
    if target_root.exists():
        raise FileExistsError(f"target directory already exists: {target_root}")
    if not public_class_ids:
        raise ValueError("public_class_ids must not be empty")
    public_class_map = {class_id: 0 for class_id in public_class_ids}
    korean_class_map = {korean_class_id: 0}
    public_counts: Counter[int] = Counter()
    korean_counts: Counter[int] = Counter()
    train_images = _copy_split(public_root, "train", target_root, "train", "public", public_class_map, public_counts)
    val_images = _copy_split(public_root, "valid", target_root, "val", "public", public_class_map, public_counts)
    test_images = sum(
        _copy_split(korean_root, split, target_root, "test", f"korean_{split}", korean_class_map, korean_counts)
        for split in ("train", "valid", "test")
    )
    (target_root / "data.yaml").write_text(
        f"train: train/images\nval: val/images\ntest: test/images\nnames:\n  0: {class_name}\n",
        encoding="utf-8",
    )
    return {
        "train_images": train_images,
        "val_images": val_images,
        "korean_test_images": test_images,
        "public_labels": public_counts[0],
        "korean_test_labels": korean_counts[0],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare public single-class training and Korean testing data.")
    parser.add_argument("--public-root", type=Path, required=True)
    parser.add_argument("--korean-root", type=Path, required=True)
    parser.add_argument("--target-root", type=Path, required=True)
    parser.add_argument("--public-class-ids", type=int, nargs="+", default=(1, 2))
    parser.add_argument("--korean-class-id", type=int, default=2)
    parser.add_argument("--class-name", default="sidewalk_pole")
    args = parser.parse_args()
    print(
        prepare_dataset(
            args.public_root,
            args.korean_root,
            args.target_root,
            public_class_ids=tuple(args.public_class_ids),
            korean_class_id=args.korean_class_id,
            class_name=args.class_name,
        )
    )


if __name__ == "__main__":
    main()
