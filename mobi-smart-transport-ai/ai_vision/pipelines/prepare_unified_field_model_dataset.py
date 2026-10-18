"""기존 버스·문·킥보드·기둥·나무·정류장 데이터를 하나의 YOLO 데이터셋으로 만든다.

통합 모델은 다음 여섯 클래스만 사용한다.

``bus``, ``bus_door``, ``parked_pm``, ``pole``, ``tree_trunk``, ``bus_stop``

각 원본 데이터셋이 이미 학습·검증·테스트로 나뉘어 있으므로, 이 도구는 같은 split끼리만
합친다. 특히 AI Hub 보행 데이터는 촬영 시퀀스 단위로 미리 분할된 결과를 사용한다.
"""

from __future__ import annotations

import argparse
import os
import shutil
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


CLASS_NAMES = ("bus", "bus_door", "parked_pm", "pole", "tree_trunk", "bus_stop")
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


@dataclass(frozen=True)
class Source:
    name: str
    root: Path
    split_names: dict[str, str]
    class_map: dict[int, int]


def _sources(root: Path) -> tuple[Source, ...]:
    temporary = root / ".tool-tmp"
    return (
        Source(
            name="bus_door",
            root=temporary / "public_bus_door_v1",
            split_names={"train": "train", "val": "val", "test": "test"},
            class_map={0: 0, 1: 1},
        ),
        Source(
            name="parked_pm",
            root=temporary / "obstacle_v1_training" / "kickboard_source",
            split_names={"train": "train", "val": "valid", "test": "test"},
            class_map={0: 2},
        ),
        Source(
            name="sidewalk_pole_tree_stop_v1",
            root=temporary / "aihub_sidewalk_pole_tree_stop_v1",
            split_names={"train": "train", "val": "val", "test": "test"},
            class_map={0: 3, 1: 4, 2: 5},
        ),
        Source(
            name="sidewalk_pole_tree_stop_v2",
            root=temporary / "aihub_sidewalk_pole_tree_stop_v2",
            split_names={"train": "train", "val": "val", "test": "test"},
            class_map={0: 3, 1: 4, 2: 5},
        ),
    )


def _remap_label(source_label: Path, target_label: Path, class_map: dict[int, int]) -> Counter[int]:
    counts: Counter[int] = Counter()
    lines: list[str] = []
    if source_label.is_file():
        for line_number, line in enumerate(source_label.read_text(encoding="utf-8").splitlines(), start=1):
            fields = line.split()
            if not fields:
                continue
            try:
                original_class = int(fields[0])
            except ValueError as exc:
                raise ValueError(f"invalid class at {source_label}:{line_number}") from exc
            if original_class not in class_map:
                continue
            target_class = class_map[original_class]
            lines.append(" ".join([str(target_class), *fields[1:]]))
            counts[target_class] += 1
    target_label.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return counts


def _materialize_image(source: Path, target: Path) -> None:
    """Prefer a relative symbolic link; fall back to a hard link or a copy.

    The generated dataset is consumed inside the Docker training container and never
    modifies image pixels. A relative link avoids repeatedly copying the large local
    AI Hub image set through Docker's Windows folder share.
    """
    try:
        os.symlink(os.path.relpath(source, start=target.parent), target)
    except OSError:
        try:
            os.link(source, target)
        except OSError:
            shutil.copy2(source, target)


def prepare_dataset(project_root: Path, output: Path) -> dict[str, dict[str, int]]:
    """Copy and remap all source images/labels into *output*; target must be new."""
    if output.exists():
        raise FileExistsError(f"output already exists: {output}")

    sources = _sources(project_root)
    for source in sources:
        if not source.root.is_dir():
            raise FileNotFoundError(f"source dataset missing: {source.root}")

    report: dict[str, dict[str, int]] = {}
    for split in ("train", "val", "test"):
        image_dir = output / split / "images"
        label_dir = output / split / "labels"
        image_dir.mkdir(parents=True)
        label_dir.mkdir(parents=True)
        image_count = 0
        box_counts: Counter[int] = Counter()

        for source in sources:
            source_split = source.root / source.split_names[split]
            source_images = source_split / "images"
            source_labels = source_split / "labels"
            if not source_images.is_dir() or not source_labels.is_dir():
                raise FileNotFoundError(f"expected YOLO images/labels under: {source_split}")

            for image in sorted(source_images.iterdir()):
                if not image.is_file() or image.suffix.lower() not in IMAGE_SUFFIXES:
                    continue
                target_stem = f"{source.name}__{image.stem}"
                target_image = image_dir / f"{target_stem}{image.suffix.lower()}"
                target_label = label_dir / f"{target_stem}.txt"
                _materialize_image(image, target_image)
                box_counts.update(_remap_label(source_labels / f"{image.stem}.txt", target_label, source.class_map))
                image_count += 1

        report[split] = {"images": image_count, **{name: box_counts[index] for index, name in enumerate(CLASS_NAMES)}}

    yaml_lines = [
        f"path: {output.resolve().as_posix()}",
        "train: train/images",
        "val: val/images",
        "test: test/images",
        "names:",
        *[f"  {index}: {name}" for index, name in enumerate(CLASS_NAMES)],
        "",
    ]
    (output / "data.yaml").write_text("\n".join(yaml_lines), encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare the six-class unified field-test YOLO dataset.")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    project_root = Path(__file__).resolve().parents[2]
    report = prepare_dataset(project_root, args.output)
    for split, counts in report.items():
        print(split, " ".join(f"{key}={value}" for key, value in counts.items()))
    print(f"Unified dataset written: {args.output}")


if __name__ == "__main__":
    main()
