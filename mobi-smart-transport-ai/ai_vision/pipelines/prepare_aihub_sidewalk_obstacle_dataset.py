"""AI Hub 인도보행 XML을 보도·정류장 YOLO 데이터셋으로 변환한다.

원본 사진과 XML은 변경하지 않는다. XML 한 파일은 같은 보행 촬영 시퀀스의 연속
프레임 묶음이므로, train/val/test는 **XML 파일 단위**로 나눈다. 이 규칙은 거의 같은
프레임이 학습과 평가에 동시에 들어가 성능이 부풀려지는 문제를 막는다.
"""

from __future__ import annotations

import argparse
import math
import shutil
import xml.etree.ElementTree as ET
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


# AI Hub의 ``stop``은 벤치 또는 쉘터가 있는 버스/택시 정류장이다. 표지판만 있는
# 정류장은 원천 라벨 정의에서 제외되므로, 앱에서는 "정류장 후보"로만 사용한다.
CLASS_IDS = {"pole": 0, "tree_trunk": 1, "stop": 2}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}


@dataclass(frozen=True)
class Frame:
    sequence_id: str
    image_path: Path
    width: int
    height: int
    boxes: tuple[tuple[int, float, float, float, float], ...]


def _yolo_box(box: ET.Element, width: int, height: int, class_id: int) -> tuple[int, float, float, float, float] | None:
    """CVAT의 xtl/ytl/xbr/ybr 박스를 경계 안의 YOLO 좌표로 바꾼다."""
    try:
        left = max(0.0, float(box.attrib["xtl"]))
        top = max(0.0, float(box.attrib["ytl"]))
        right = min(float(width), float(box.attrib["xbr"]))
        bottom = min(float(height), float(box.attrib["ybr"]))
    except (KeyError, ValueError):
        return None
    values = (left, top, right, bottom)
    if not all(math.isfinite(value) for value in values) or right <= left or bottom <= top:
        return None
    return (
        class_id,
        (left + right) / (2 * width),
        (top + bottom) / (2 * height),
        (right - left) / width,
        (bottom - top) / height,
    )


def collect_frames(source_root: Path) -> tuple[list[Frame], Counter[str]]:
    """XML과 같은 폴더의 실제 사진만 수집한다."""
    if not source_root.is_dir():
        raise FileNotFoundError(f"source directory does not exist: {source_root}")

    report: Counter[str] = Counter()
    frames: list[Frame] = []
    for xml_path in sorted(source_root.rglob("*.xml")):
        sequence_id = f"{xml_path.parent.name}_{xml_path.stem}"
        root = ET.parse(xml_path).getroot()
        report["xml_files"] += 1
        for image in root.findall("image"):
            try:
                image_name = image.attrib["name"]
                width, height = int(image.attrib["width"]), int(image.attrib["height"])
            except (KeyError, ValueError):
                report["invalid_image_metadata"] += 1
                continue
            image_path = xml_path.parent / image_name
            if image_path.suffix.lower() not in IMAGE_EXTENSIONS or not image_path.is_file():
                report["missing_images"] += 1
                continue
            if width <= 0 or height <= 0:
                report["invalid_image_metadata"] += 1
                continue

            boxes = []
            for box in image.findall("box"):
                label = box.attrib.get("label")
                if label not in CLASS_IDS:
                    continue
                converted = _yolo_box(box, width, height, CLASS_IDS[label])
                if converted is None:
                    report["invalid_boxes"] += 1
                    continue
                boxes.append(converted)
                report[f"{label}_boxes"] += 1
            frames.append(Frame(sequence_id, image_path, width, height, tuple(boxes)))
            report["frames"] += 1
    return frames, report


def _split_sequences(frames: list[Frame]) -> dict[str, list[Frame]]:
    """시퀀스(XML) 단위로 70/15/15 분할한다."""
    sequence_ids = sorted({frame.sequence_id for frame in frames})
    if len(sequence_ids) < 3:
        raise ValueError("at least three XML sequences are required for train/val/test")
    train_end = round(len(sequence_ids) * 0.70)
    val_end = train_end + round(len(sequence_ids) * 0.15)
    split_for_sequence = {
        **{sequence_id: "train" for sequence_id in sequence_ids[:train_end]},
        **{sequence_id: "val" for sequence_id in sequence_ids[train_end:val_end]},
        **{sequence_id: "test" for sequence_id in sequence_ids[val_end:]},
    }
    result: dict[str, list[Frame]] = {"train": [], "val": [], "test": []}
    for frame in frames:
        result[split_for_sequence[frame.sequence_id]].append(frame)
    return result


def _label_lines(frame: Frame) -> str:
    return "".join(
        f"{class_id} {x_center:.8f} {y_center:.8f} {box_width:.8f} {box_height:.8f}\n"
        for class_id, x_center, y_center, box_width, box_height in frame.boxes
    )


def prepare_dataset(source_root: Path, target_root: Path) -> dict[str, int]:
    """AI Hub 보행 프레임을 기둥·나무·정류장 YOLO 데이터셋으로 복사·변환한다."""
    if target_root.exists():
        raise FileExistsError(f"target directory already exists: {target_root}")
    frames, report = collect_frames(source_root)
    if not frames:
        raise ValueError("no usable image/XML frame pairs found")

    for split in ("train", "val", "test"):
        report[f"{split}_frames"] = 0
        report[f"{split}_boxes"] = 0
    for split, split_frames in _split_sequences(frames).items():
        images_dir = target_root / split / "images"
        labels_dir = target_root / split / "labels"
        images_dir.mkdir(parents=True)
        labels_dir.mkdir(parents=True)
        for index, frame in enumerate(split_frames):
            output_stem = f"{frame.sequence_id}_{index:05d}"
            shutil.copy2(frame.image_path, images_dir / f"{output_stem}{frame.image_path.suffix.lower()}")
            (labels_dir / f"{output_stem}.txt").write_text(_label_lines(frame), encoding="utf-8")
            report[f"{split}_frames"] += 1
            report[f"{split}_boxes"] += len(frame.boxes)
    (target_root / "data.yaml").write_text(
        "train: train/images\nval: val/images\ntest: test/images\nnames:\n  0: pole\n  1: tree_trunk\n  2: bus_stop\n",
        encoding="utf-8",
    )
    return dict(report)


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert AI Hub pedestrian XML to a pole/tree_trunk/bus_stop YOLO dataset.")
    parser.add_argument("--source", type=Path, required=True, help="directory containing Bbox_* folders")
    parser.add_argument("--target", type=Path, required=True, help="new YOLO dataset directory")
    args = parser.parse_args()
    print(prepare_dataset(args.source, args.target))


if __name__ == "__main__":
    main()
