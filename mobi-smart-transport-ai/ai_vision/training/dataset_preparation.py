"""Review-gated preparation of the first three-class YOLO dataset.

The archive readers never extract or modify source archives. Every candidate
starts unreviewed; conversion requires both box-level decisions and an
image-level completeness decision, plus a verified source group.
"""
from __future__ import annotations

import csv
import hashlib
import json
import math
import re
import shutil
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable, Mapping, Sequence

from ai_vision.training.dataset_validation import (
    DEFAULT_MAPPING,
    DEFAULT_TAXONOMY,
    load_training_classes,
    validate_dataset,
    validate_development_train_only_dataset,
)


REVIEW_STATUSES = {"approved", "needs_correction", "rejected", "uncertain", "unreviewed"}
COMPLETENESS_STATUSES = {"complete", "reviewed_negative", "incomplete", "uncertain", "unreviewed"}
SPLITS = ("train", "val", "test")
SOURCE_TO_TARGET = {
    "aihub": {"bus": "bus", "stop": "bus_stop"},
    "roboflow": {"Front_door": "bus_door", "Rear_door": "bus_door"},
}
BOX_MANIFEST_FIELDS = (
    "image_id", "box_id", "source_dataset", "source_image", "source_annotation",
    "source_class", "target_class", "bbox", "review_status", "review_reason",
    "corrected_bbox", "source_group", "source_group_status", "original_hash",
    "source_license", "source_url",
)
IMAGE_MANIFEST_FIELDS = (
    "image_id", "source_dataset", "source_image", "source_annotation", "source_group",
    "source_group_status", "source_group_reason", "original_hash", "source_split", "source_frame_id",
    "is_augmented", "completeness_status", "completeness_reason", "parse_issues",
    "source_license", "source_url",
)
ADDITIONAL_ANNOTATION_FIELDS = (
    "source_dataset", "image_id", "source_image", "source_annotation", "new_box_id",
    "target_class", "bbox_coordinates", "coordinate_format", "review_status",
    "review_reason", "reviewer", "reviewed_at", "original_hash", "image_width",
    "image_height", "corrected_bbox_coordinates", "source_group", "source_license", "source_url",
)


class PreparationError(ValueError):
    """Raised when source or review data cannot safely be converted."""


@dataclass(frozen=True)
class BoxCandidate:
    image_id: str
    box_id: str
    source_dataset: str
    source_image: str
    source_annotation: str
    source_class: str
    target_class: str
    bbox: tuple[float, float, float, float]
    bbox_format: str
    source_group: str
    source_group_status: str
    source_license: str
    source_url: str


@dataclass(frozen=True)
class ImageCandidate:
    image_id: str
    source_dataset: str
    source_image: str
    source_annotation: str
    source_group: str
    source_group_status: str
    source_frame_id: str
    source_split: str
    is_augmented: bool
    source_license: str
    source_url: str
    boxes: tuple[BoxCandidate, ...] = ()
    parse_issues: tuple[str, ...] = ()
    archive_path: Path | None = field(default=None, compare=False)
    archive_member: str = ""


@dataclass(frozen=True)
class ReviewedImage:
    candidate: ImageCandidate
    source_group: str
    source_group_reason: str
    completeness_reason: str
    labels: tuple[tuple[str, tuple[float, float, float, float], str], ...]
    original_hash: str
    label_provenance: tuple[dict[str, str], ...] = ()
    source_group_status: str = "unverified"


@dataclass
class ReviewPlan:
    eligible: list[ReviewedImage] = field(default_factory=list)
    review_queue: list[tuple[str, str]] = field(default_factory=list)
    box_counts: Counter[str] = field(default_factory=Counter)
    image_counts: Counter[str] = field(default_factory=Counter)


@dataclass
class ConversionResult:
    output_dir: Path | None
    converted_images: int = 0
    converted_boxes: int = 0
    split_counts: dict[str, int] = field(default_factory=lambda: {split: 0 for split in SPLITS})
    review_queue: list[tuple[str, str]] = field(default_factory=list)
    validation_errors: list[str] = field(default_factory=list)


def select_images_by_id(images: Sequence[ImageCandidate], image_ids: Iterable[str]) -> list[ImageCandidate]:
    """Restrict review/conversion to an explicit batch; reject stale or duplicate IDs."""
    selected_ids = list(image_ids)
    if not selected_ids or any(not image_id.strip() for image_id in selected_ids):
        raise PreparationError("An explicit, non-empty image ID selection is required.")
    if len(set(selected_ids)) != len(selected_ids):
        raise PreparationError("Image ID selection contains duplicates.")
    by_id = {image.image_id: image for image in images}
    missing = sorted(set(selected_ids) - set(by_id))
    if missing:
        raise PreparationError(f"Unknown image ID(s) in selected batch: {missing[:5]}")
    return [by_id[image_id] for image_id in selected_ids]


def _stable_id(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()


def _hash_zip_member(archive: zipfile.ZipFile, member: str) -> str:
    return hashlib.sha256(archive.read(member)).hexdigest()


def _candidate_source_group(source: str, annotation: str, task_name: str = "") -> str:
    if source == "aihub":
        # XML/task grouping is only a candidate until a human confirms capture-session identity.
        task = task_name.strip() or Path(annotation).stem
        return f"aihub:{Path(annotation).parent.as_posix()}:{task}"
    return ""


def _image_id(source: str, source_image: str, source_annotation: str) -> str:
    return _stable_id(source, source_annotation, source_image)


def parse_cvat_archive(path: Path) -> list[ImageCandidate]:
    """Read target annotations from CVAT image XML files inside an AI-Hub ZIP."""
    import xml.etree.ElementTree as ET

    path = Path(path)
    records: list[ImageCandidate] = []
    with zipfile.ZipFile(path) as archive:
        members = set(archive.namelist())
        for xml_member in sorted(name for name in members if name.lower().endswith(".xml")):
            try:
                root = ET.fromstring(archive.read(xml_member))
            except ET.ParseError as exc:
                raise PreparationError(f"Malformed CVAT XML {xml_member}: {exc}") from exc
            task_name = root.findtext("./meta/task/name", default="")
            candidate_group = _candidate_source_group("aihub", xml_member, task_name)
            group_status = "unverified"
            for image_node in root.findall(".//image"):
                filename = image_node.attrib.get("name", "")
                if not filename:
                    raise PreparationError(f"CVAT image without name in {xml_member}.")
                member = f"{Path(xml_member).parent.as_posix()}/{filename}"
                image_id = _image_id("aihub", member, xml_member)
                issues = () if member in members else ("missing_source_image",)
                boxes: list[BoxCandidate] = []
                width = float(image_node.attrib.get("width", "0"))
                height = float(image_node.attrib.get("height", "0"))
                for box_index, node in enumerate(image_node.findall("box")):
                    source_class = node.attrib.get("label", "")
                    target_class = SOURCE_TO_TARGET["aihub"].get(source_class)
                    if target_class is None:
                        continue
                    try:
                        bbox = tuple(float(node.attrib[key]) for key in ("xtl", "ytl", "xbr", "ybr"))
                        _validate_xyxy(bbox, width, height)
                    except (KeyError, ValueError) as exc:
                        raise PreparationError(f"Invalid CVAT bbox {xml_member}:{filename}:{box_index}: {exc}") from exc
                    box_id = f"{image_id}:box-{box_index:04d}"
                    boxes.append(BoxCandidate(
                        image_id, box_id, "aihub", member, xml_member, source_class,
                        target_class, bbox, "xyxy_pixel", candidate_group, group_status,
                        "not_recorded_in_this_manifest", "",
                    ))
                records.append(ImageCandidate(
                    image_id=image_id, source_dataset="aihub", source_image=member,
                    source_annotation=xml_member, source_group=candidate_group,
                    source_group_status=group_status, source_frame_id=f"{xml_member}:{filename}",
                    source_split="", is_augmented=False,
                    source_license="not_recorded_in_this_manifest", source_url="",
                    boxes=tuple(boxes), parse_issues=issues, archive_path=path,
                    archive_member=member,
                ))
    return records


def _parse_source_yaml(archive: zipfile.ZipFile) -> dict[str, object]:
    import yaml

    yaml_members = [member for member in archive.namelist() if member.rstrip("/") == "data.yaml"]
    if not yaml_members:
        raise PreparationError("Roboflow ZIP is missing root data.yaml.")
    configs = [yaml.safe_load(archive.read(member).decode("utf-8")) for member in yaml_members]
    if not all(config == configs[0] for config in configs[1:]):
        raise PreparationError("Roboflow ZIP contains conflicting data.yaml entries.")
    if not isinstance(configs[0], dict):
        raise PreparationError("Roboflow data.yaml must contain a YAML mapping.")
    return configs[0]


def _roboflow_frame_and_group(stem: str) -> tuple[str, str]:
    source_frame = re.sub(r"_jpg\.rf\.[0-9a-fA-F]+$", "", stem)
    frame_match = re.match(r"^(.*)_frame_\d+$", source_frame)
    if frame_match:
        return source_frame, f"roboflow:{frame_match.group(1)}"
    numbered_match = re.match(r"^(.+?)_\d{5}$", source_frame)
    if numbered_match:
        return source_frame, f"roboflow:{numbered_match.group(1)}"
    return source_frame, f"roboflow:{source_frame}"


def parse_roboflow_archive(path: Path) -> list[ImageCandidate]:
    """Read YOLO image/label pairs from the Roboflow export without extraction."""
    path = Path(path)
    records: list[ImageCandidate] = []
    with zipfile.ZipFile(path) as archive:
        config = _parse_source_yaml(archive)
        raw_names = config.get("names")
        if isinstance(raw_names, list):
            names = [str(item) for item in raw_names]
        elif isinstance(raw_names, dict):
            try:
                names = [str(raw_names[key] if key in raw_names else raw_names[str(key)]) for key in range(len(raw_names))]
            except (KeyError, TypeError) as exc:
                raise PreparationError("Roboflow data.yaml names must use contiguous IDs starting at zero.") from exc
        else:
            raise PreparationError("Roboflow data.yaml must define class names.")
        if names != ["Front_door", "Rear_door"]:
            raise PreparationError(f"Unexpected Roboflow class order: {names!r}.")
        provenance = config.get("roboflow", {})
        if not isinstance(provenance, dict):
            provenance = {}
        source_license = str(provenance.get("license") or "not_recorded_in_this_manifest")
        source_url = str(provenance.get("url") or "https://universe.roboflow.com/bus-door/bus-open-door/dataset/2")
        members = set(archive.namelist())
        for image_member in sorted(
            name for name in members
            if "/images/" in name and Path(name).suffix.lower() in {".jpg", ".jpeg", ".png"}
        ):
            split = image_member.split("/", 1)[0]
            if split not in {"train", "valid", "test"}:
                continue
            filename = Path(image_member).name
            label_member = image_member.replace("/images/", "/labels/")
            label_member = str(Path(label_member).with_suffix(".txt")).replace("\\", "/")
            image_id = _image_id("roboflow", image_member, label_member)
            stem = Path(filename).stem
            frame_id, group = _roboflow_frame_and_group(stem)
            issues: list[str] = []
            if label_member not in members:
                issues.append("missing_source_label")
            boxes: list[BoxCandidate] = []
            if label_member in members:
                for box_index, line in enumerate(archive.read(label_member).decode("utf-8-sig").splitlines()):
                    if not line.strip():
                        continue
                    fields = line.split()
                    if len(fields) != 5:
                        raise PreparationError(f"Malformed YOLO row {label_member}:{box_index + 1}.")
                    try:
                        class_id = int(fields[0])
                        cx, cy, width, height = map(float, fields[1:])
                    except ValueError as exc:
                        raise PreparationError(f"Non-numeric YOLO row {label_member}:{box_index + 1}.") from exc
                    if class_id not in (0, 1):
                        raise PreparationError(f"Unsupported source class ID {class_id} in {label_member}.")
                    _validate_yolo_bbox((cx, cy, width, height))
                    bbox = (cx - width / 2, cy - height / 2, cx + width / 2, cy + height / 2)
                    source_class = names[class_id]
                    box_id = f"{image_id}:box-{box_index:04d}"
                    boxes.append(BoxCandidate(
                        image_id, box_id, "roboflow", image_member, label_member,
                        source_class, SOURCE_TO_TARGET["roboflow"][source_class],
                        bbox, "xyxy_normalized", group, "unverified", source_license,
                        source_url,
                    ))
            records.append(ImageCandidate(
                image_id=image_id, source_dataset="roboflow", source_image=image_member,
                source_annotation=label_member, source_group=group,
                source_group_status="unverified", source_frame_id=f"roboflow:{frame_id}",
                source_split=split, is_augmented=(split == "train"),
                source_license=source_license,
                source_url=source_url,
                boxes=tuple(boxes), parse_issues=tuple(issues), archive_path=path,
                archive_member=image_member,
            ))
    return records


def _validate_xyxy(bbox: Sequence[float], width: float, height: float) -> None:
    if len(bbox) != 4 or not all(math.isfinite(value) for value in bbox):
        raise ValueError("bbox must contain four finite coordinates")
    x1, y1, x2, y2 = bbox
    if width <= 0 or height <= 0 or not (0 <= x1 < x2 <= width and 0 <= y1 < y2 <= height):
        raise ValueError("pixel bbox must be positive and inside image bounds")


def _validate_yolo_bbox(bbox: Sequence[float]) -> None:
    if len(bbox) != 4 or not all(math.isfinite(value) for value in bbox):
        raise ValueError("YOLO bbox must contain four finite values")
    cx, cy, width, height = bbox
    if not (0 <= cx <= 1 and 0 <= cy <= 1 and 0 < width <= 1 and 0 < height <= 1):
        raise ValueError("YOLO bbox values must be normalized")
    if cx - width / 2 < 0 or cx + width / 2 > 1 or cy - height / 2 < 0 or cy + height / 2 > 1:
        raise ValueError("YOLO bbox extends outside image bounds")


def bbox_to_yolo(bbox: Sequence[float], bbox_format: str, width: int, height: int) -> tuple[float, float, float, float]:
    """Convert pixel/normalized xyxy coordinates to normalized YOLO xywh."""
    if bbox_format == "xyxy_pixel":
        _validate_xyxy(bbox, width, height)
        x1, y1, x2, y2 = bbox
        normalized = (x1 / width, y1 / height, x2 / width, y2 / height)
    elif bbox_format == "xyxy_normalized":
        x1, y1, x2, y2 = bbox
        _validate_yolo_bbox(((x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1))
        normalized = tuple(bbox)
    else:
        raise ValueError(f"Unsupported bbox format: {bbox_format!r}.")
    x1, y1, x2, y2 = normalized
    result = ((x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1)
    _validate_yolo_bbox(result)
    return result


def bbox_json(box: BoxCandidate) -> str:
    return json.dumps({"format": box.bbox_format, "xyxy": list(box.bbox)}, separators=(",", ":"))


def write_review_manifests(
    images: Sequence[ImageCandidate],
    box_path: Path,
    image_path: Path,
    *,
    compute_hashes: bool = True,
) -> None:
    """Write editable review queues. All decisions start unreviewed."""
    image_path = Path(image_path)
    box_path = Path(box_path)
    image_path.parent.mkdir(parents=True, exist_ok=True)
    box_path.parent.mkdir(parents=True, exist_ok=True)
    image_hashes: dict[str, str] = {}
    if compute_hashes:
        archives: dict[Path, zipfile.ZipFile] = {}
        try:
            for image in images:
                if image.archive_path is None or not image.archive_member:
                    continue
                archive = archives.get(image.archive_path)
                if archive is None:
                    archive = zipfile.ZipFile(image.archive_path)
                    archives[image.archive_path] = archive
                if image.archive_member in archive.namelist():
                    image_hashes[image.image_id] = _hash_zip_member(archive, image.archive_member)
        finally:
            for archive in archives.values():
                archive.close()
    with image_path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=IMAGE_MANIFEST_FIELDS)
        writer.writeheader()
        for image in images:
            writer.writerow({
                "image_id": image.image_id,
                "source_dataset": image.source_dataset,
                "source_image": image.source_image,
                "source_annotation": image.source_annotation,
                "source_group": image.source_group,
                "source_group_status": image.source_group_status,
                "source_group_reason": "",
                "original_hash": image_hashes.get(image.image_id, ""),
                "source_split": image.source_split,
                "source_frame_id": image.source_frame_id,
                "is_augmented": str(image.is_augmented).lower(),
                "completeness_status": "unreviewed",
                "completeness_reason": "",
                "parse_issues": json.dumps(list(image.parse_issues), ensure_ascii=False),
                "source_license": image.source_license,
                "source_url": image.source_url,
            })
    with box_path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=BOX_MANIFEST_FIELDS)
        writer.writeheader()
        for image in images:
            for box in image.boxes:
                writer.writerow({
                    "image_id": box.image_id,
                    "box_id": box.box_id,
                    "source_dataset": box.source_dataset,
                    "source_image": box.source_image,
                    "source_annotation": box.source_annotation,
                    "source_class": box.source_class,
                    "target_class": box.target_class,
                    "bbox": bbox_json(box),
                    "review_status": "unreviewed",
                    "review_reason": "",
                    "corrected_bbox": "",
                    "source_group": box.source_group,
                    "source_group_status": box.source_group_status,
                    "original_hash": image_hashes.get(box.image_id, ""),
                    "source_license": box.source_license,
                    "source_url": box.source_url,
                })


def create_review_preview(image: ImageCandidate, output_dir: Path, *, box_statuses: Mapping[str, str] | None = None) -> list[Path]:
    """Create one overlay per image with box ID/class/status; source archive is read-only."""
    if image.archive_path is None or not image.archive_member:
        raise PreparationError("Preview requires an archive-backed image candidate.")
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as exc:
        raise PreparationError("Pillow is required for preview generation.") from exc
    statuses = box_statuses or {}
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(image.archive_path) as archive:
        if image.archive_member not in archive.namelist():
            raise PreparationError(f"Missing image in source archive: {image.archive_member}.")
        from io import BytesIO
        picture = Image.open(BytesIO(archive.read(image.archive_member))).convert("RGB")
    draw = ImageDraw.Draw(picture)
    try:
        font = ImageFont.truetype("arial.ttf", 18)
    except OSError:
        font = ImageFont.load_default()
    width, height = picture.size
    for box in image.boxes:
        if box.bbox_format == "xyxy_pixel":
            coords = box.bbox
        else:
            x1, y1, x2, y2 = box.bbox
            coords = (x1 * width, y1 * height, x2 * width, y2 * height)
        status = statuses.get(box.box_id, "unreviewed")
        color = (0, 180, 60) if status == "approved" else (245, 165, 0) if status == "needs_correction" else (245, 40, 40)
        draw.rectangle(coords, outline=color, width=max(2, width // 320))
        caption = f"{box.target_class} | {box.box_id} | {status}"
        draw.text((max(0, coords[0]), max(0, coords[1] - 22)), caption, fill=color, font=font, stroke_width=2, stroke_fill="white")
    filename = f"{image.source_dataset}_{image.image_id[:16]}.jpg"
    path = output_dir / filename
    picture.save(path, quality=94)
    return [path]


def create_annotation_workbench(
    images: Sequence[ImageCandidate], output_dir: Path, *, image_ids: Iterable[str]
) -> Path:
    """Copy only selected source images to an external, browser-based bbox review workbench."""
    selected_ids = list(dict.fromkeys(image_ids))
    by_id = {image.image_id: image for image in images}
    missing = sorted(set(selected_ids) - set(by_id))
    if missing:
        raise PreparationError(f"Unknown image ID(s) for workbench: {missing[:5]}")
    if not selected_ids:
        raise PreparationError("Select at least one image ID for the annotation workbench.")
    output_dir = Path(output_dir)
    if output_dir.exists() and any(output_dir.iterdir()):
        raise PreparationError(f"Workbench output directory must be absent or empty: {output_dir}")
    image_dir = output_dir / "images"
    image_dir.mkdir(parents=True, exist_ok=True)
    records = []
    from io import BytesIO
    try:
        from PIL import Image
    except ImportError as exc:
        raise PreparationError("Pillow is required to create the annotation workbench.") from exc
    archives: dict[Path, zipfile.ZipFile] = {}
    try:
        for image_id in selected_ids:
            candidate = by_id[image_id]
            if candidate.archive_path is None or not candidate.archive_member:
                raise PreparationError(f"No archive image recorded for {image_id}.")
            archive = archives.get(candidate.archive_path)
            if archive is None:
                archive = zipfile.ZipFile(candidate.archive_path)
                archives[candidate.archive_path] = archive
            try:
                payload = archive.read(candidate.archive_member)
            except KeyError as exc:
                raise PreparationError(f"Missing source image: {candidate.archive_member}.") from exc
            with Image.open(BytesIO(payload)) as picture:
                width, height = picture.size
            filename = f"{image_id[:20]}{Path(candidate.source_image).suffix.lower() or '.jpg'}"
            (image_dir / filename).write_bytes(payload)
            boxes = []
            for box in candidate.boxes:
                coords = box.bbox
                if box.bbox_format == "xyxy_normalized":
                    coords = (coords[0] * width, coords[1] * height, coords[2] * width, coords[3] * height)
                boxes.append({"boxId": box.box_id, "className": box.target_class, "bbox": list(coords)})
            records.append({
                "imageId": candidate.image_id,
                "sourceDataset": candidate.source_dataset,
                "sourceImage": candidate.source_image,
                "sourceAnnotation": candidate.source_annotation,
                "sourceGroup": candidate.source_group,
                "sourceLicense": candidate.source_license,
                "sourceUrl": candidate.source_url,
                "originalHash": hashlib.sha256(payload).hexdigest(),
                "width": width,
                "height": height,
                "imageUrl": f"images/{filename}",
                "boxes": boxes,
            })
    finally:
        for archive in archives.values():
            archive.close()

    index_path = output_dir / "workbench.json"
    index_path.write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
    html_path = output_dir / "index.html"
    embedded_data = json.dumps(records, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    html_path.write_text(_ANNOTATION_WORKBENCH_HTML.replace("__WORKBENCH_DATA__", embedded_data), encoding="utf-8")
    return html_path


def write_additional_annotation_template(path: Path) -> None:
    """Create an empty sidecar header; annotations are added by the workbench or reviewer."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        csv.DictWriter(stream, fieldnames=ADDITIONAL_ANNOTATION_FIELDS).writeheader()


_ANNOTATION_WORKBENCH_HTML = r'''<!doctype html>
<html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI Vision 추가 bbox 검수</title>
<style>body{font:15px system-ui;margin:1rem;background:#f4f6f8;color:#17212b}header{position:sticky;top:0;background:white;padding:.75rem;border:1px solid #ccd4dc;z-index:2}button,select{padding:.45rem;margin:.2rem}#stage{position:relative;width:min(100%,1200px);margin:1rem auto;background:#111}canvas{display:block;width:100%;height:auto;cursor:crosshair}#status{font-weight:600}.help{font-size:.9rem}</style>
<header><button id="prev">이전</button><select id="images"></select><button id="next">다음</button>
<label>추가 클래스 <select id="class"><option>bus</option><option>bus_door</option><option>bus_stop</option></select></label>
<button id="undo">마지막 추가 박스 삭제</button><button id="export">additional_annotations.csv 내보내기</button>
<span id="status"></span><p class="help">드래그로 신규 bbox를 그립니다. 초록색은 원본 라벨(수정 불가), 주황색은 이 검수 세션에서 추가한 제안입니다. 내보낸 신규 라벨은 항상 unreviewed입니다.</p></header>
<div id="stage"><canvas id="canvas"></canvas></div><script>
const csvEscape=v=>'"'+String(v??'').replaceAll('"','""')+'"';
const data=__WORKBENCH_DATA__;{const c=document.querySelector('#canvas'),ctx=c.getContext('2d'),sel=document.querySelector('#images'),status=document.querySelector('#status'),img=new Image();let i=0,drawingsByImage=new Map(),start=null;
data.forEach((x,n)=>{const o=document.createElement('option');o.value=n;o.textContent=`${n+1}/${data.length} ${x.sourceDataset} ${x.sourceImage}`;sel.append(o)});
function currentDrawings(){const id=data[i].imageId;if(!drawingsByImage.has(id))drawingsByImage.set(id,[]);return drawingsByImage.get(id)}
function render(){const x=data[i],drawings=currentDrawings();img.onload=()=>{c.width=x.width;c.height=x.height;ctx.drawImage(img,0,0);ctx.lineWidth=Math.max(2,x.width/500);for(const b of x.boxes){const [a,d,e,f]=b.bbox;ctx.strokeStyle='#00b55a';ctx.strokeRect(a,d,e-a,f-d);ctx.fillStyle='#00b55a';ctx.fillText(`${b.className} | original ${b.boxId}`,a,Math.max(14,d-4))}for(const b of drawings){ctx.strokeStyle='#ff9f1c';ctx.strokeRect(b.x1,b.y1,b.x2-b.x1,b.y2-b.y1);ctx.fillStyle='#ff9f1c';ctx.fillText(`${b.targetClass} | NEW ${b.newBoxId}`,b.x1,Math.max(14,b.y1-4))}status.textContent=`${x.imageId} · ${x.width}×${x.height} · 신규 ${drawings.length}개`};img.src=x.imageUrl}
function selected(n){i=(n+data.length)%data.length;sel.value=i;render()}sel.onchange=()=>selected(Number(sel.value));document.querySelector('#prev').onclick=()=>selected(i-1);document.querySelector('#next').onclick=()=>selected(i+1);document.querySelector('#undo').onclick=()=>{currentDrawings().pop();render()};
function point(ev){const r=c.getBoundingClientRect();return{x:(ev.clientX-r.left)*c.width/r.width,y:(ev.clientY-r.top)*c.height/r.height}}c.onpointerdown=e=>{start=point(e);c.setPointerCapture(e.pointerId)};c.onpointerup=e=>{if(!start)return;const p=point(e),x1=Math.min(start.x,p.x),y1=Math.min(start.y,p.y),x2=Math.max(start.x,p.x),y2=Math.max(start.y,p.y);if(x2-x1>=16&&y2-y1>=16){const image=data[i],drawings=currentDrawings(),n=drawings.length+1;drawings.push({source_dataset:image.sourceDataset,image_id:image.imageId,source_image:image.sourceImage,source_annotation:image.sourceAnnotation,new_box_id:`additional:${image.imageId.slice(0,16)}:${String(n).padStart(4,'0')}`,target_class:document.querySelector('#class').value,bbox_coordinates:JSON.stringify([x1,y1,x2,y2]),coordinate_format:'xyxy_pixel',review_status:'unreviewed',review_reason:'',reviewer:'',reviewed_at:'',original_hash:image.originalHash,image_width:image.width,image_height:image.height,corrected_bbox_coordinates:'',source_group:image.sourceGroup,source_license:image.sourceLicense,source_url:image.sourceUrl})}start=null;render()};
document.querySelector('#export').onclick=()=>{const fields=['source_dataset','image_id','source_image','source_annotation','new_box_id','target_class','bbox_coordinates','coordinate_format','review_status','review_reason','reviewer','reviewed_at','original_hash','image_width','image_height','corrected_bbox_coordinates','source_group','source_license','source_url'];const rows=[...drawingsByImage.values()].flat();const text=[fields.map(csvEscape).join(','),...rows.map(x=>fields.map(k=>csvEscape(x[k])).join(','))].join('\r\n');const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['\ufeff'+text],{type:'text/csv'}));a.download='additional_annotations.csv';a.click();URL.revokeObjectURL(a.href)};selected(0)}
</script></html>'''


def _read_csv(path: Path, key: str) -> dict[str, dict[str, str]]:
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if not reader.fieldnames or key not in reader.fieldnames:
            raise PreparationError(f"{path} must contain a {key} column.")
        rows: dict[str, dict[str, str]] = {}
        for row in reader:
            value = (row.get(key) or "").strip()
            if not value or value in rows:
                raise PreparationError(f"{path} contains an empty or duplicate {key}: {value!r}.")
            rows[value] = row
        return rows


def build_review_plan(
    images: Sequence[ImageCandidate],
    box_manifest: Path,
    image_manifest: Path,
    additional_annotations: Path | None = None,
    *,
    require_verified_groups: bool = True,
    approved_or_rejected_only: bool = False,
) -> ReviewPlan:
    """Join image/box review separately and queue anything not fully approved."""
    boxes = _read_csv(box_manifest, "box_id")
    image_reviews = _read_csv(image_manifest, "image_id")
    additions = _read_csv(additional_annotations, "new_box_id") if additional_annotations else {}
    expected_image_ids = {image.image_id for image in images}
    expected_box_ids = {box.box_id for image in images for box in image.boxes}
    extra_images = set(image_reviews) - expected_image_ids
    extra_boxes = set(boxes) - expected_box_ids
    if extra_images or extra_boxes:
        raise PreparationError(
            f"Review manifest contains entries not present in source archives "
            f"(images={len(extra_images)}, boxes={len(extra_boxes)})."
        )
    if any(box_id in expected_box_ids for box_id in additions):
        raise PreparationError("An additional new_box_id collides with an original source box ID.")
    images_by_id = {image.image_id: image for image in images}
    extra_additions = set(additions) - {
        (row.get("new_box_id") or "").strip() for row in additions.values()
    }
    if extra_additions:
        raise PreparationError("Additional annotation IDs must be unique and non-empty.")
    additions_by_image: dict[str, list[dict[str, str]]] = defaultdict(list)
    seen_addition_ids: set[str] = set()
    for new_box_id, row in additions.items():
        image_id = (row.get("image_id") or "").strip()
        candidate = images_by_id.get(image_id)
        if candidate is None:
            raise PreparationError(f"Additional annotation references unknown image_id {image_id!r}.")
        if new_box_id in seen_addition_ids or new_box_id in expected_box_ids:
            raise PreparationError(f"Duplicate or colliding new_box_id: {new_box_id}.")
        seen_addition_ids.add(new_box_id)
        if (row.get("source_dataset") != candidate.source_dataset
                or row.get("source_image") != candidate.source_image
                or row.get("source_annotation") != candidate.source_annotation):
            raise PreparationError(f"Additional annotation source identity mismatch for {new_box_id}.")
        if (row.get("source_group") != candidate.source_group
                or row.get("source_license") != candidate.source_license
                or row.get("source_url") != candidate.source_url):
            raise PreparationError(f"Additional annotation provenance mismatch for {new_box_id}.")
        if not new_box_id.startswith(f"additional:{image_id[:16]}:"):
            raise PreparationError(f"new_box_id must use the image-scoped additional ID namespace: {new_box_id}.")
        additions_by_image[image_id].append(row)
    plan = ReviewPlan()
    for image in images:
        image_row = image_reviews.get(image.image_id)
        if image_row is None:
            plan.review_queue.append((image.image_id, "missing image-level completeness review"))
            plan.image_counts["missing_review"] += 1
            continue
        if (image_row.get("source_dataset") != image.source_dataset
                or image_row.get("source_image") != image.source_image
                or image_row.get("source_annotation") != image.source_annotation):
            raise PreparationError(f"Image identity fields changed in review manifest for {image.image_id}.")
        if not (image_row.get("original_hash") or "").strip():
            plan.review_queue.append((image.image_id, "original_hash is missing; regenerate the review manifest with hashes"))
            plan.image_counts["missing_hash"] += 1
            continue
        group = (image_row.get("source_group") or "").strip()
        source_group_reason = (image_row.get("source_group_reason") or "").strip()
        group_status = (image_row.get("source_group_status") or "").strip()
        if require_verified_groups and (group_status != "verified" or not group or not source_group_reason):
            plan.review_queue.append((image.image_id, "source_group is unverified"))
            plan.image_counts["unverified_group"] += 1
            continue
        if not group or group_status not in {"verified", "unverified"}:
            plan.review_queue.append((image.image_id, "source group identity/status is invalid"))
            plan.image_counts["invalid_source_group"] += 1
            continue
        if image.parse_issues:
            plan.review_queue.append((image.image_id, "; ".join(image.parse_issues)))
            plan.image_counts["parse_issue"] += 1
            continue
        completeness = image_row.get("completeness_status", "unreviewed")
        if completeness not in COMPLETENESS_STATUSES:
            raise PreparationError(f"Invalid completeness status {completeness!r} for {image.image_id}.")
        if completeness not in {"complete", "reviewed_negative"}:
            plan.review_queue.append((image.image_id, f"image completeness is {completeness}"))
            plan.image_counts[completeness] += 1
            continue
        completeness_reason = (image_row.get("completeness_reason") or "").strip()
        if not completeness_reason:
            plan.review_queue.append((image.image_id, "image completeness review requires a reason"))
            plan.image_counts["missing_reason"] += 1
            continue
        labels: list[tuple[str, tuple[float, float, float, float], str]] = []
        label_provenance: list[dict[str, str]] = []
        blocked = False
        for box in image.boxes:
            row = boxes.get(box.box_id)
            if row is None:
                plan.review_queue.append((image.image_id, f"missing box review for {box.box_id}"))
                plan.box_counts["missing_review"] += 1
                blocked = True
                continue
            if (row.get("image_id") != box.image_id
                    or row.get("source_image") != box.source_image
                    or row.get("source_annotation") != box.source_annotation
                    or row.get("source_class") != box.source_class
                    or row.get("target_class") != box.target_class):
                raise PreparationError(f"Source identity fields changed in review manifest for {box.box_id}.")
            status = row.get("review_status", "unreviewed")
            if status not in REVIEW_STATUSES:
                raise PreparationError(f"Invalid review status {status!r} for {box.box_id}.")
            plan.box_counts[status] += 1
            if approved_or_rejected_only and status not in {"approved", "rejected"}:
                plan.review_queue.append((image.image_id, f"box {box.box_id} must be approved or rejected for development conversion"))
                blocked = True
                continue
            reason = (row.get("review_reason") or "").strip()
            if status in {"needs_correction", "rejected", "uncertain"} and not reason:
                plan.review_queue.append((image.image_id, f"box {box.box_id} requires a review_reason"))
                blocked = True
                continue
            if status == "approved":
                bbox_json_value = row.get("bbox", "")
            elif status == "needs_correction" and row.get("corrected_bbox", "").strip():
                bbox_json_value = row["corrected_bbox"]
            elif status == "rejected":
                continue
            else:
                plan.review_queue.append((image.image_id, f"box {box.box_id} is {status} or lacks corrected_bbox"))
                blocked = True
                continue
            try:
                payload = json.loads(bbox_json_value)
                fmt = payload["format"]
                coords = tuple(float(value) for value in payload["xyxy"])
                if status == "approved" and (fmt != box.bbox_format or coords != box.bbox):
                    raise ValueError("approved bbox must preserve source coordinates; use needs_correction")
                if fmt == "xyxy_pixel":
                    # Image dimensions are obtained from the archive only during conversion/preview.
                    _validate_positive_xyxy(coords)
                elif fmt == "xyxy_normalized":
                    _validate_yolo_bbox(((coords[0] + coords[2]) / 2, (coords[1] + coords[3]) / 2, coords[2] - coords[0], coords[3] - coords[1]))
                else:
                    raise ValueError("unsupported bbox format")
            except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
                raise PreparationError(f"Invalid reviewed bbox for {box.box_id}: {exc}") from exc
            labels.append((box.target_class, coords, fmt))
            label_provenance.append({
                "annotation_source": "source", "box_id": box.box_id, "review_status": "approved",
                "review_reason": reason,
            })
        for row in additions_by_image.get(image.image_id, []):
            new_box_id = row["new_box_id"]
            status = row.get("review_status", "unreviewed")
            if status not in REVIEW_STATUSES:
                raise PreparationError(f"Invalid additional annotation review status {status!r} for {new_box_id}.")
            plan.box_counts[f"additional_{status}"] += 1
            reason = (row.get("review_reason") or "").strip()
            if status in {"needs_correction", "rejected", "uncertain"} and not reason:
                plan.review_queue.append((image.image_id, f"new box {new_box_id} requires a review_reason"))
                blocked = True
                continue
            if status == "rejected":
                continue
            if status != "approved":
                plan.review_queue.append((image.image_id, f"new box {new_box_id} is {status}; explicit approval is required"))
                blocked = True
                continue
            if not (row.get("reviewer") or "").strip() or not (row.get("reviewed_at") or "").strip():
                plan.review_queue.append((image.image_id, f"new box {new_box_id} approval requires reviewer and reviewed_at"))
                blocked = True
                continue
            if not reason:
                plan.review_queue.append((image.image_id, f"new box {new_box_id} approval requires a review_reason"))
                blocked = True
                continue
            try:
                reviewed_at = datetime.fromisoformat(row["reviewed_at"].strip().replace("Z", "+00:00"))
                if reviewed_at.tzinfo is None or reviewed_at.utcoffset() is None:
                    raise ValueError("reviewed_at must include a timezone")
            except (KeyError, ValueError) as exc:
                raise PreparationError(f"Invalid reviewed_at for {new_box_id}: {exc}") from exc
            if not row.get("original_hash", "").strip() or row["original_hash"].lower() != image_row.get("original_hash", "").lower():
                raise PreparationError(f"Additional annotation original_hash mismatch for {new_box_id}.")
            try:
                from io import BytesIO
                from PIL import Image
                payload = _source_image_bytes(image)
                if hashlib.sha256(payload).hexdigest() != row["original_hash"].lower():
                    raise ValueError("sidecar hash does not match source image bytes")
                with Image.open(BytesIO(payload)) as picture:
                    width, height = picture.size
                if int(row.get("image_width", "0")) != width or int(row.get("image_height", "0")) != height:
                    raise ValueError("recorded image dimensions do not match source image")
                coords_raw = row.get("corrected_bbox_coordinates", "").strip() or row.get("bbox_coordinates", "")
                coords_value = json.loads(coords_raw)
                if isinstance(coords_value, dict):
                    coords_value = coords_value.get("xyxy")
                coords = tuple(float(value) for value in coords_value)
                fmt = row.get("coordinate_format", "")
                if fmt == "xyxy_pixel":
                    _validate_xyxy(coords, width, height)
                    pixel_box = coords
                elif fmt == "xyxy_normalized":
                    if len(coords) != 4:
                        raise ValueError("normalized xyxy bbox must have four coordinates")
                    pixel_box = (coords[0] * width, coords[1] * height, coords[2] * width, coords[3] * height)
                    _validate_xyxy(pixel_box, width, height)
                else:
                    raise ValueError("coordinate_format must be xyxy_pixel or xyxy_normalized")
                if pixel_box[2] - pixel_box[0] < 16 or pixel_box[3] - pixel_box[1] < 16:
                    raise ValueError("new bbox must be at least 16 pixels wide and high")
                target_class = row.get("target_class", "")
                if target_class not in {"bus", "bus_door", "bus_stop"}:
                    raise ValueError(f"unsupported 3-class target_class {target_class!r}")
            except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError) as exc:
                raise PreparationError(f"Invalid additional bbox {new_box_id}: {exc}") from exc
            labels.append((target_class, coords, fmt))
            label_provenance.append({
                "annotation_source": "additional",
                "box_id": new_box_id,
                "review_status": "approved",
                "review_reason": reason,
                "reviewer": row["reviewer"].strip(),
                "reviewed_at": row["reviewed_at"].strip(),
            })
        if blocked:
            continue
        if completeness == "complete" and not labels:
            plan.review_queue.append((image.image_id, "complete image review has no approved target box"))
            plan.image_counts["missing_approved_box"] += 1
            continue
        if completeness == "reviewed_negative" and labels:
            plan.review_queue.append((image.image_id, "negative image review conflicts with approved boxes"))
            plan.image_counts["negative_conflict"] += 1
            continue
        original_hash = (image_row.get("original_hash") or "").strip()
        plan.eligible.append(ReviewedImage(
            image, group, source_group_reason, completeness_reason, tuple(labels), original_hash,
            tuple(label_provenance), group_status,
        ))
        plan.image_counts[completeness] += 1
    return plan


def build_development_train_only_plan(
    images: Sequence[ImageCandidate],
    box_manifest: Path,
    image_manifest: Path,
    completeness_checklist: Path,
    additional_annotations: Path | None = None,
) -> ReviewPlan:
    """Build a development-only plan while preserving (not verifying) source groups.

    This path still requires image-level and box-level human decisions. It does
    not assign evaluation splits and is not suitable for model evaluation.
    """
    plan = build_review_plan(
        images, box_manifest, image_manifest, additional_annotations,
        require_verified_groups=False, approved_or_rejected_only=True,
    )
    with Path(completeness_checklist).open(encoding="utf-8-sig", newline="") as stream:
        checklist_reader = csv.DictReader(stream)
        required_checklist_columns = {
            "image_id", "source_dataset", "source_image", "contains_bus", "bus_annotation_complete",
            "contains_bus_door", "bus_door_annotation_complete", "contains_bus_stop", "bus_stop_annotation_complete",
        }
        if not checklist_reader.fieldnames or not required_checklist_columns.issubset(checklist_reader.fieldnames):
            raise PreparationError("Completeness checklist is missing image identity or required class review columns.")
        checklist_rows = list(checklist_reader)
    checklist: dict[str, dict[str, str]] = {}
    for row in checklist_rows:
        image_id = (row.get("image_id") or "").strip()
        if not image_id or image_id in checklist:
            raise PreparationError(f"Completeness checklist has an empty or duplicate image_id: {image_id!r}.")
        checklist[image_id] = row
    selected_ids = {image.image_id for image in images}
    extra = set(checklist) - selected_ids
    if extra:
        raise PreparationError(f"Completeness checklist contains {len(extra)} image(s) outside the selected source batch.")
    checklist_by_id = checklist
    image_rows = _read_csv(image_manifest, "image_id")
    checked: list[ReviewedImage] = []
    blocked_ids: set[str] = set()
    negative_ids = {
        image_id for image_id, row in image_rows.items()
        if image_id in selected_ids and row.get("completeness_status") == "reviewed_negative"
    }
    candidate_by_id = {image.image_id: image for image in images}
    for image_id in sorted(selected_ids - set(checklist_by_id)):
        plan.review_queue.append((image_id, "missing per-class completeness checklist row"))
        plan.image_counts["missing_class_completeness"] += 1
        blocked_ids.add(image_id)
    for image_id, row in checklist_by_id.items():
        candidate = candidate_by_id.get(image_id)
        if candidate is None:
            continue
        if row.get("source_dataset") != candidate.source_dataset or row.get("source_image") != candidate.source_image:
            raise PreparationError(f"Completeness checklist image identity mismatch for {image_id}.")
    source_reviews_for_integrity = _read_csv(box_manifest, "box_id")
    from io import BytesIO
    from PIL import Image
    for image in images:
        row = image_rows.get(image.image_id, {})
        try:
            payload = _source_image_bytes(image)
            actual_hash = hashlib.sha256(payload).hexdigest()
            if not row.get("original_hash") or row["original_hash"].lower() != actual_hash:
                raise ValueError("original_hash does not match source image bytes")
            with Image.open(BytesIO(payload)) as picture:
                width, height = picture.size
                picture.verify()
            for box in image.boxes:
                if source_reviews_for_integrity.get(box.box_id, {}).get("review_status") == "approved":
                    bbox_to_yolo(box.bbox, box.bbox_format, width, height)
        except (OSError, ValueError) as exc:
            blocked_ids.add(image.image_id)
            reason = f"source image/hash/bbox integrity check failed: {exc}"
            plan.review_queue.append((image.image_id, reason))
            plan.image_counts["source_integrity_error"] += 1
    for item in plan.eligible:
        if item.candidate.image_id in blocked_ids:
            continue
        if item.candidate.image_id in negative_ids:
            continue
        row = checklist_by_id.get(item.candidate.image_id)
        if row is None:
            plan.review_queue.append((item.candidate.image_id, "missing per-class completeness checklist row"))
            plan.image_counts["missing_class_completeness"] += 1
            blocked_ids.add(item.candidate.image_id)
            continue
        for target_class in ("bus", "bus_door", "bus_stop"):
            contains = (row.get(f"contains_{target_class}") or "").strip().lower()
            complete = (row.get(f"{target_class}_annotation_complete") or "").strip().lower()
            if contains not in {"yes", "no"} or complete not in {"yes", "no"}:
                plan.review_queue.append((item.candidate.image_id, f"{target_class} presence/completeness is not a definite yes/no"))
                plan.image_counts[f"{target_class}_checklist_uncertain"] += 1
                blocked_ids.add(item.candidate.image_id)
                continue
            if complete != "yes":
                plan.review_queue.append((item.candidate.image_id, f"{target_class} annotation completeness is not approved"))
                plan.image_counts[f"{target_class}_annotation_incomplete"] += 1
                blocked_ids.add(item.candidate.image_id)
            if contains == "yes" and not any(label[0] == target_class for label in item.labels):
                plan.review_queue.append((item.candidate.image_id, f"{target_class} is marked visible but has no approved bbox"))
                plan.image_counts[f"{target_class}_missing_approved_box"] += 1
                blocked_ids.add(item.candidate.image_id)
            if contains == "no" and any(label[0] == target_class for label in item.labels):
                plan.review_queue.append((item.candidate.image_id, f"approved {target_class} bbox conflicts with checklist absence"))
                plan.image_counts[f"{target_class}_approved_box_conflict"] += 1
                blocked_ids.add(item.candidate.image_id)
        if item.candidate.is_augmented and item.candidate.source_dataset == "roboflow" and item.candidate.source_split != "train":
            plan.review_queue.append((item.candidate.image_id, "augmentation/source-split provenance is inconsistent"))
            plan.image_counts["augmentation_provenance_conflict"] += 1
            blocked_ids.add(item.candidate.image_id)
        if item.candidate.image_id not in blocked_ids:
            payload = _source_image_bytes(item.candidate)
            digest = hashlib.sha256(payload).hexdigest()
            try:
                from io import BytesIO
                from PIL import Image
                with Image.open(BytesIO(payload)) as picture:
                    width, height = picture.size
                pixel_boxes: list[tuple[str, tuple[float, float, float, float], str]] = []
                for target_class, bbox, fmt in item.labels:
                    bbox_to_yolo(bbox, fmt, width, height)
                    if fmt == "xyxy_pixel":
                        pixel_bbox = tuple(float(value) for value in bbox)
                    else:
                        pixel_bbox = (bbox[0] * width, bbox[1] * height, bbox[2] * width, bbox[3] * height)
                    if pixel_bbox[2] - pixel_bbox[0] <= 0 or pixel_bbox[3] - pixel_bbox[1] <= 0:
                        raise ValueError("bbox must have positive area")
                    pixel_boxes.append((target_class, pixel_bbox, fmt))
                duplicate = _duplicate_reviewed_boxes(pixel_boxes)
                if duplicate is not None:
                    raise ValueError(f"approved annotations overlap as a duplicate ({duplicate})")
            except (OSError, ValueError) as exc:
                plan.review_queue.append((item.candidate.image_id, f"image/bbox integrity check failed: {exc}"))
                plan.image_counts["image_or_bbox_integrity_error"] += 1
                continue
            checked.append(item)
    approved_classes: dict[str, set[str]] = defaultdict(set)
    source_reviews = _read_csv(box_manifest, "box_id")
    for image in images:
        for box in image.boxes:
            row = source_reviews.get(box.box_id, {})
            if row.get("review_status") == "approved":
                approved_classes[image.image_id].add(box.target_class)
    additional_reviews = _read_csv(additional_annotations, "new_box_id") if additional_annotations else {}
    for row in additional_reviews.values():
        if row.get("review_status") == "approved":
            approved_classes[(row.get("image_id") or "").strip()].add((row.get("target_class") or "").strip())
    queue_set = set(plan.review_queue)
    for image in images:
        if image.image_id in negative_ids:
            continue
        row = checklist_by_id.get(image.image_id)
        if row is None:
            continue  # Missing rows are reported for otherwise eligible items above.
        for target_class in ("bus", "bus_door", "bus_stop"):
            contains = (row.get(f"contains_{target_class}") or "").strip().lower()
            complete = (row.get(f"{target_class}_annotation_complete") or "").strip().lower()
            if contains not in {"yes", "no"} or complete not in {"yes", "no"}:
                reason = f"{target_class} presence/completeness is not a definite yes/no"
            elif complete != "yes":
                reason = f"{target_class} annotation completeness is not approved"
            elif contains == "yes" and target_class not in approved_classes[image.image_id]:
                reason = f"{target_class} is marked visible but has no approved bbox"
            elif contains == "no" and target_class in approved_classes[image.image_id]:
                reason = f"approved {target_class} bbox conflicts with checklist absence"
            else:
                continue
            blocked_ids.add(image.image_id)
            if (image.image_id, reason) not in queue_set:
                plan.review_queue.append((image.image_id, reason))
                plan.image_counts[f"{target_class}_checklist_conflict"] += 1
                queue_set.add((image.image_id, reason))
    plan.eligible = [item for item in checked if item.candidate.image_id not in blocked_ids]
    plan.image_counts["reviewed_negative_excluded"] = len(negative_ids)
    return plan


def _duplicate_reviewed_boxes(
    boxes: Sequence[tuple[str, tuple[float, float, float, float], str]],
) -> str | None:
    """Find near-identical same-class boxes after coordinates are in pixels."""
    for index, (class_a, box_a, _) in enumerate(boxes):
        for class_b, box_b, _ in boxes[index + 1:]:
            if class_a != class_b:
                continue
            if all(abs(a - b) <= 1.0 for a, b in zip(box_a, box_b)):
                return class_a
    return None


def _validate_positive_xyxy(bbox: Sequence[float]) -> None:
    if len(bbox) != 4 or not all(math.isfinite(value) for value in bbox):
        raise ValueError("bbox must have four finite coordinates")
    if not (0 <= bbox[0] < bbox[2] and 0 <= bbox[1] < bbox[3]):
        raise ValueError("bbox must have positive extent")


def assign_group_splits(
    images: Sequence[ReviewedImage],
    *,
    seed: int = 42,
    ratios: tuple[float, float, float] = (0.8, 0.1, 0.1),
) -> dict[str, str]:
    """Deterministically assign whole verified groups; never split individual frames."""
    if len(ratios) != 3 or any(value <= 0 for value in ratios) or not math.isclose(sum(ratios), 1.0, abs_tol=1e-9):
        raise ValueError("ratios must be three positive values summing to 1")
    groups = sorted({image.source_group for image in images})
    if len(groups) < 3:
        raise PreparationError("At least three verified source groups are required to create train/val/test.")
    order = sorted(groups, key=lambda group: hashlib.sha256(f"{seed}:{group}".encode()).hexdigest())
    counts = [math.floor(len(order) * ratio) for ratio in ratios]
    for split_index in sorted(range(3), key=lambda index: (-(len(order) * ratios[index] - counts[index]), index))[:len(order) - sum(counts)]:
        counts[split_index] += 1
    for index in range(3):
        if counts[index] == 0:
            donor = max(range(3), key=lambda item: counts[item])
            counts[donor] -= 1
            counts[index] = 1
    assignments: dict[str, str] = {}
    cursor = 0
    for split, count in zip(SPLITS, counts):
        for group in order[cursor:cursor + count]:
            assignments[group] = split
        cursor += count
    return assignments


def dry_run_summary(images: Sequence[ImageCandidate]) -> dict[str, object]:
    """Return counts only; does not create output, hash image payloads, or copy data."""
    source_counts = Counter(image.source_dataset for image in images)
    class_counts = Counter((image.source_dataset, box.source_class, box.target_class) for image in images for box in image.boxes)
    candidate_groups: dict[str, set[str]] = defaultdict(set)
    for image in images:
        candidate_groups[image.source_group].add(image.source_split)
    split_collisions = [
        group for group, source_splits in candidate_groups.items()
        if group and len(source_splits - {""}) > 1
    ]
    return {
        "images": dict(sorted(source_counts.items())),
        "candidate_boxes": {"|".join(key): value for key, value in sorted(class_counts.items())},
        "source_group_candidates": len(candidate_groups),
        "groups_appearing_in_multiple_original_splits": len(split_collisions),
        "unreviewed_images": len(images),
        "unverified_source_groups": len(candidate_groups),
        "parse_issues": sum(bool(image.parse_issues) for image in images),
        "annotation_completeness": "requires human review for every image; cross-class omissions cannot be inferred from source labels",
        "split_feasibility": "blocked until source groups are manually verified",
        "files_written": 0,
        "source_archives_modified": False,
    }


def _source_image_bytes(image: ImageCandidate) -> bytes:
    if image.archive_path is None:
        raise PreparationError(f"No source archive recorded for {image.image_id}.")
    with zipfile.ZipFile(image.archive_path) as archive:
        try:
            return archive.read(image.archive_member)
        except KeyError as exc:
            raise PreparationError(f"Missing source image: {image.archive_member}.") from exc


def convert_reviewed_dataset(
    images: Sequence[ImageCandidate],
    box_manifest: Path,
    image_manifest: Path,
    output_dir: Path,
    *,
    max_images: int,
    seed: int = 42,
    mapping_path: Path = DEFAULT_MAPPING,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
    additional_annotations: Path | None = None,
    apply: bool = False,
) -> ConversionResult:
    """Convert explicitly reviewed images. Writes only with apply=True and a cap."""
    if max_images <= 0:
        raise ValueError("max_images must be a positive limit; unbounded conversion is disabled")
    result = ConversionResult(output_dir=None)
    plan = build_review_plan(images, box_manifest, image_manifest, additional_annotations)
    result.review_queue = plan.review_queue
    if not apply:
        return result
    if result.review_queue:
        raise PreparationError(f"Conversion blocked: {len(result.review_queue)} image(s) remain in review queue.")
    classes = load_training_classes(mapping_path, taxonomy_path)
    taxonomy_to_id = {item.taxonomy_id: item.yolo_id for item in classes}
    expected = {"bus", "bus_door", "bus_stop"}
    if set(taxonomy_to_id) != expected:
        raise PreparationError(f"This converter requires exactly the three-class mapping {sorted(expected)}.")
    group_splits = assign_group_splits(plan.eligible, seed=seed)
    by_group: dict[str, list[ReviewedImage]] = defaultdict(list)
    for item in plan.eligible:
        by_group[item.source_group].append(item)
    selected_groups: list[str] = []
    selected_count = 0
    for group in sorted(by_group, key=lambda value: hashlib.sha256(f"{seed}:{value}".encode()).hexdigest()):
        group_size = sum(not (item.candidate.is_augmented and group_splits[group] != "train") for item in by_group[group])
        if selected_count + group_size <= max_images:
            selected_groups.append(group)
            selected_count += group_size
    selected = [item for group in selected_groups for item in by_group[group]
                if not (item.candidate.is_augmented and group_splits[group] != "train")]
    if selected_count == 0:
        raise PreparationError("No reviewed images fit the requested max_images cap.")
    if not apply:
        return result
    output_dir = Path(output_dir)
    output_preexisted = output_dir.exists()
    if output_dir.exists() and any(output_dir.iterdir()):
        raise PreparationError(f"Output directory must be absent or empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    for split in SPLITS:
        (output_dir / "images" / split).mkdir(parents=True, exist_ok=True)
        (output_dir / "labels" / split).mkdir(parents=True, exist_ok=True)
    manifest_rows: list[dict[str, str]] = []
    try:
        for item in selected:
            candidate = item.candidate
            split = group_splits[item.source_group]
            payload = _source_image_bytes(candidate)
            digest = hashlib.sha256(payload).hexdigest()
            if item.original_hash and item.original_hash.lower() != digest:
                raise PreparationError(f"original_hash mismatch for {candidate.source_image}.")
            suffix = Path(candidate.source_image).suffix.lower() or ".jpg"
            filename = f"{candidate.image_id[:20]}{suffix}"
            image_rel = f"images/{split}/{filename}"
            image_out = output_dir / image_rel
            image_out.write_bytes(payload)
            label_lines: list[str] = []
            review_records: list[dict[str, str]] = []
            for label_index, (target_class, bbox, bbox_format) in enumerate(item.labels):
                yolo_id = taxonomy_to_id[target_class]
                if bbox_format == "xyxy_pixel":
                    from io import BytesIO
                    from PIL import Image
                    with Image.open(BytesIO(payload)) as picture:
                        width, height = picture.size
                else:
                    width = height = 1
                cx, cy, box_width, box_height = bbox_to_yolo(bbox, bbox_format, width, height)
                label_lines.append(f"{yolo_id} {cx:.8f} {cy:.8f} {box_width:.8f} {box_height:.8f}")
                review_records.append({
                    "target_class": target_class,
                    "bbox": list(bbox),
                    **(item.label_provenance[label_index] if item.label_provenance else {}),
                })
            (output_dir / "labels" / split / f"{Path(filename).stem}.txt").write_text(
                "\n".join(label_lines) + ("\n" if label_lines else ""), encoding="utf-8"
            )
            manifest_rows.append({
                "image": image_rel,
                "split": split,
                "source_group": item.source_group,
                "source_dataset": candidate.source_dataset,
                "source_image": candidate.source_image,
                "source_annotation": candidate.source_annotation,
                "source_frame_id": candidate.source_frame_id,
                "source_group_reason": item.source_group_reason,
                "target_annotations": json.dumps(review_records, ensure_ascii=False, separators=(",", ":")),
                "completeness_status": "reviewed_negative" if not item.labels else "complete",
                "completeness_reason": item.completeness_reason,
                "original_hash": digest,
                "source_license": candidate.source_license,
                "source_url": candidate.source_url,
                "review_status": "approved",
                "transformation": "source copy; normalized xyxy to YOLO xywh" if item.labels else "reviewed negative; empty label",
                "augmentation_status": "source_augmented_train_only" if candidate.is_augmented and split == "train" else "none",
            })
            result.converted_boxes += len(item.labels)
            result.converted_images += 1
            result.split_counts[split] += 1
        fields = (
            "image", "split", "source_group", "source_dataset", "source_image",
            "source_annotation", "source_frame_id", "source_group_reason", "target_annotations",
            "completeness_status", "completeness_reason",
            "original_hash", "source_license", "source_url", "review_status",
            "transformation", "augmentation_status",
        )
        with (output_dir / "dataset_manifest.csv").open("w", encoding="utf-8-sig", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows(manifest_rows)
        (output_dir / "dataset.yaml").write_text(
            "path: .\ntrain: images/train\nval: images/val\ntest: images/test\nnames:\n  0: bus\n  1: bus_door\n  2: bus_stop\n",
            encoding="utf-8",
        )
        report = validate_dataset(output_dir / "dataset.yaml", mapping_path=mapping_path, taxonomy_path=taxonomy_path)
        result.validation_errors = [issue.message for issue in report.errors]
        if result.validation_errors:
            raise PreparationError(f"Generated dataset failed validator: {result.validation_errors[:3]}")
    except Exception:
        # Do not leave a partial dataset that could be mistaken for a successful conversion.
        if not output_preexisted:
            shutil.rmtree(output_dir, ignore_errors=True)
        else:
            for child in output_dir.iterdir():
                shutil.rmtree(child, ignore_errors=True) if child.is_dir() else child.unlink(missing_ok=True)
        raise
    result.output_dir = output_dir
    return result


def convert_development_train_only_dataset(
    images: Sequence[ImageCandidate],
    box_manifest: Path,
    image_manifest: Path,
    completeness_checklist: Path,
    additional_annotations: Path | None,
    output_dir: Path,
    *,
    max_images: int,
    mapping_path: Path,
    taxonomy_path: Path = DEFAULT_TAXONOMY,
    apply: bool = False,
) -> ConversionResult:
    """Write a non-evaluation, train-only copy using explicit human reviews."""
    if max_images <= 0:
        raise ValueError("max_images must be a positive limit; unbounded conversion is disabled")
    plan = build_development_train_only_plan(
        images, box_manifest, image_manifest, completeness_checklist, additional_annotations
    )
    result = ConversionResult(output_dir=None, review_queue=plan.review_queue)
    if not apply:
        return result
    if plan.review_queue:
        causes = Counter(reason for _, reason in plan.review_queue)
        details = "; ".join(f"{count}× {reason}" for reason, count in causes.most_common(5))
        raise PreparationError(
            f"Development train-only conversion blocked: {len(plan.review_queue)} review item(s) remain. {details}"
        )
    if not plan.eligible:
        raise PreparationError("No approved non-negative images are available for development conversion.")
    classes = load_training_classes(mapping_path, taxonomy_path)
    taxonomy_to_id = {item.taxonomy_id: item.yolo_id for item in classes}
    expected = {"bus", "bus_door", "bus_stop"}
    if set(taxonomy_to_id) != expected:
        raise PreparationError(f"Development converter requires exactly the three-class mapping {sorted(expected)}.")
    if len(plan.eligible) > max_images:
        raise PreparationError(
            f"Approved development images ({len(plan.eligible)}) exceed --max-images={max_images}; no partial silent conversion."
        )
    output_dir = Path(output_dir)
    if output_dir.exists() and any(output_dir.iterdir()):
        raise PreparationError(f"Output directory must be absent or empty: {output_dir}")
    output_preexisted = output_dir.exists()
    output_dir.mkdir(parents=True, exist_ok=True)
    for relative in ("images/train", "labels/train"):
        (output_dir / relative).mkdir(parents=True, exist_ok=True)

    manifest_rows: list[dict[str, str]] = []
    class_counts: Counter[str] = Counter()
    try:
        for item in plan.eligible:
            candidate = item.candidate
            payload = _source_image_bytes(candidate)
            digest = hashlib.sha256(payload).hexdigest()
            if not item.original_hash or item.original_hash.lower() != digest:
                raise PreparationError(f"original_hash mismatch for {candidate.source_image}.")
            from io import BytesIO
            from PIL import Image
            with Image.open(BytesIO(payload)) as picture:
                width, height = picture.size
                picture.verify()
            suffix = Path(candidate.source_image).suffix.lower() or ".jpg"
            filename = f"{candidate.image_id[:20]}{suffix}"
            image_rel = f"images/train/{filename}"
            (output_dir / image_rel).write_bytes(payload)
            label_lines: list[str] = []
            review_records: list[dict[str, str]] = []
            for index, (target_class, bbox, bbox_format) in enumerate(item.labels):
                if target_class not in taxonomy_to_id:
                    raise PreparationError(f"Unsupported reviewed class {target_class!r} in {candidate.image_id}.")
                cx, cy, box_width, box_height = bbox_to_yolo(bbox, bbox_format, width, height)
                # Preserve round-trip precision for boxes touching an image edge.
                label_lines.append(
                    f"{taxonomy_to_id[target_class]} {cx:.17g} {cy:.17g} {box_width:.17g} {box_height:.17g}"
                )
                class_counts[target_class] += 1
                provenance = dict(item.label_provenance[index]) if item.label_provenance else {}
                review_records.append({
                    "target_class": target_class,
                    "bbox": list(bbox),
                    "coordinate_format": bbox_format,
                    **provenance,
                })
            label_rel = f"labels/train/{Path(filename).stem}.txt"
            (output_dir / label_rel).write_text("\n".join(label_lines) + "\n", encoding="utf-8")
            manifest_rows.append({
                "image": image_rel,
                "split": "train",
                "dataset_mode": "development_train_only",
                "evaluation_eligible": "false",
                "source_group": item.source_group,
                "source_group_status": item.source_group_status,
                "source_group_reason": item.source_group_reason,
                "source_dataset": candidate.source_dataset,
                "source_image": candidate.source_image,
                "source_annotation": candidate.source_annotation,
                "source_frame_id": candidate.source_frame_id,
                "is_augmented_source": str(candidate.is_augmented).lower(),
                "target_annotations": json.dumps(review_records, ensure_ascii=False, separators=(",", ":")),
                "completeness_status": "complete",
                "completeness_reason": item.completeness_reason,
                "original_hash": digest,
                "image_width": str(width),
                "image_height": str(height),
                "source_license": candidate.source_license,
                "source_url": candidate.source_url,
                "review_status": "approved",
                "transformation": "source copy; normalized xyxy to YOLO xywh",
            })
            result.converted_images += 1
            result.converted_boxes += len(item.labels)
            result.split_counts["train"] += 1

        fields = (
            "image", "split", "dataset_mode", "evaluation_eligible", "source_group",
            "source_group_status", "source_group_reason", "source_dataset", "source_image",
            "source_annotation", "source_frame_id", "is_augmented_source", "target_annotations",
            "completeness_status", "completeness_reason", "original_hash", "image_width",
            "image_height", "source_license", "source_url", "review_status", "transformation",
        )
        with (output_dir / "dataset_manifest.csv").open("w", encoding="utf-8-sig", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            writer.writerows(manifest_rows)
        data_yaml = (
            "# Development-only YOLO files; NOT a runnable Ultralytics training YAML.\n"
            "# Ultralytics requires both train and val; do not reuse train as val.\n"
            "path: .\ntrain: images/train\n"
            "names:\n  0: bus\n  1: bus_door\n  2: bus_stop\n"
        )
        (output_dir / "data.yaml").write_text(data_yaml, encoding="utf-8")
        report_data = {
            "dataset_mode": "development_train_only",
            "evaluation_eligible": False,
            "all_source_groups_verified": all(item.source_group_status == "verified" for item in plan.eligible),
            "source_group_policy": "preserve review CSV status; no group split or verification implied",
            "warning": "Do not use this dataset for validation, test, or performance claims.",
            "images": result.converted_images,
            "labels": result.converted_images,
            "boxes": result.converted_boxes,
            "class_counts": {name: class_counts[name] for name in ("bus", "bus_door", "bus_stop")},
            "source_group_status_counts": dict(Counter(item.source_group_status for item in plan.eligible)),
            "excluded_reviewed_negative_images": plan.image_counts.get("reviewed_negative_excluded", 0),
            "source_archives_modified": False,
        }
        (output_dir / "conversion_report.json").write_text(
            json.dumps(report_data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        report = validate_development_train_only_dataset(
            output_dir / "data.yaml", mapping_path=mapping_path, taxonomy_path=taxonomy_path
        )
        result.validation_errors = [issue.message for issue in report.errors]
        if result.validation_errors:
            raise PreparationError(f"Development dataset failed validation: {result.validation_errors[:5]}")
    except Exception:
        if not output_preexisted:
            shutil.rmtree(output_dir, ignore_errors=True)
        else:
            for child in output_dir.iterdir():
                shutil.rmtree(child, ignore_errors=True) if child.is_dir() else child.unlink(missing_ok=True)
        raise
    result.output_dir = output_dir
    return result
