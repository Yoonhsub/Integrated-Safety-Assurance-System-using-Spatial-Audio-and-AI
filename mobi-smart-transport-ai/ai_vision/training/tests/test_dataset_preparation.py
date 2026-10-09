from __future__ import annotations

import csv
import io
import zipfile
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest
from PIL import Image

from ai_vision.training.dataset_preparation import (
    PreparationError,
    assign_group_splits,
    bbox_to_yolo,
    build_review_plan,
    convert_reviewed_dataset,
    create_review_preview,
    dry_run_summary,
    parse_cvat_archive,
    parse_roboflow_archive,
    write_review_manifests,
)
from ai_vision.training.dataset_validation import DEFAULT_TAXONOMY, load_training_classes
from scripts.prepare_ai_vision_dataset import main as prepare_main


def _image_bytes(color: tuple[int, int, int]) -> bytes:
    image = Image.new("RGB", (100, 80), color)
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    return buffer.getvalue()


def _write_cvat_zip(path: Path, count: int = 1) -> None:
    root = "Bbox_1_new"
    xml_images = []
    with zipfile.ZipFile(path, "w") as archive:
        for index in range(count):
            name = f"bus_{index}.jpg"
            archive.writestr(f"{root}/{name}", _image_bytes((index * 50, 10, 20)))
            xml_images.append(
                f'<image id="{index}" name="{name}" width="100" height="80">'
                '<box label="bus" xtl="10" ytl="8" xbr="50" ybr="48"/>'
                '<box label="stop" xtl="55" ytl="8" xbr="90" ybr="70"/>'
                '<box label="pole" xtl="1" ytl="1" xbr="5" ybr="70"/>'
                "</image>"
            )
        xml = "<annotations><meta><task><name>session-candidate</name></task></meta>" + "".join(xml_images) + "</annotations>"
        archive.writestr(f"{root}/annotations.xml", xml)


def _write_roboflow_zip(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("data.yaml", "train: train/images\nval: valid/images\ntest: test/images\nnames:\n  0: Front_door\n  1: Rear_door\nroboflow:\n  license: CC BY 4.0\n  url: https://universe.roboflow.com/bus-door/bus-open-door/dataset/2\n")
        for split, stem in (("train", "recording_frame_0001_jpg.rf.a1"), ("valid", "recording_frame_0002_jpg.rf.b2"), ("test", "recording_frame_0003_jpg.rf.c3")):
            archive.writestr(f"{split}/images/{stem}.jpg", _image_bytes((len(stem), 20, 30)))
            archive.writestr(f"{split}/labels/{stem}.txt", "1 0.5 0.5 0.4 0.6\n")


def _edit_csv(path: Path, key: str, updates: dict[str, dict[str, str]]) -> None:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
        fields = list(rows[0]) if rows else []
    for row in rows:
        row.update(updates.get(row[key], {}))
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def test_three_class_mapping_aligns_to_taxonomy_and_preserves_four_class_mapping() -> None:
    from ai_vision.training.dataset_validation import DEFAULT_MAPPING

    mapping = Path(__file__).parents[1] / "class_mapping_3class.json"
    classes = load_training_classes(mapping, DEFAULT_TAXONOMY)
    assert [(item.yolo_id, item.taxonomy_id) for item in classes] == [
        (0, "bus"), (1, "bus_door"), (2, "bus_stop")
    ]
    assert len(load_training_classes(DEFAULT_MAPPING, DEFAULT_TAXONOMY)) == 4


def test_cvat_xml_parsing_maps_only_bus_and_stop_and_converts_pixel_bbox(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    assert len(images) == 1
    assert [(box.source_class, box.target_class) for box in images[0].boxes] == [
        ("bus", "bus"), ("stop", "bus_stop")
    ]
    assert bbox_to_yolo((10, 8, 50, 48), "xyxy_pixel", 100, 80) == pytest.approx((0.3, 0.35, 0.4, 0.5))
    assert images[0].source_group_status == "unverified"


def test_roboflow_yolo_parsing_maps_source_classes_and_marks_train_augmentation(tmp_path: Path) -> None:
    source = tmp_path / "doors.zip"
    _write_roboflow_zip(source)
    images = parse_roboflow_archive(source)
    assert {box.target_class for image in images for box in image.boxes} == {"bus_door"}
    train = next(image for image in images if image.source_split == "train")
    assert train.is_augmented
    assert train.boxes[0].source_class == "Rear_door"
    assert train.boxes[0].source_license == "CC BY 4.0"
    assert bbox_to_yolo(train.boxes[0].bbox, "xyxy_normalized", 1, 1) == pytest.approx((0.5, 0.5, 0.4, 0.6))


def test_review_manifests_start_unreviewed_and_separate_image_from_box_decisions(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(images, box_csv, image_csv)
    with box_csv.open(encoding="utf-8-sig", newline="") as stream:
        boxes = list(csv.DictReader(stream))
    with image_csv.open(encoding="utf-8-sig", newline="") as stream:
        image_rows = list(csv.DictReader(stream))
    assert len(boxes) == 2
    assert all(row["review_status"] == "unreviewed" for row in boxes)
    assert all(row["completeness_status"] == "unreviewed" for row in image_rows)
    assert all(len(row["original_hash"]) == 64 for row in image_rows)
    assert {"source_dataset", "source_image", "source_annotation", "source_class", "target_class", "bbox", "source_group", "original_hash"}.issubset(boxes[0])


def test_preview_is_written_outside_source_and_labels_box_and_review_state(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    image = parse_cvat_archive(source)[0]
    before = source.read_bytes()
    preview_files = create_review_preview(image, tmp_path / "previews")
    assert len(preview_files) == 1
    assert preview_files[0].is_file()
    with Image.open(preview_files[0]) as preview:
        assert preview.size == (100, 80)
    assert source.read_bytes() == before


def test_review_gate_blocks_unreviewed_boxes_incomplete_images_and_unverified_groups(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(images, box_csv, image_csv)
    plan = build_review_plan(images, box_csv, image_csv)
    assert not plan.eligible
    assert len(plan.review_queue) == 1
    assert "unverified" in plan.review_queue[0][1]
    _edit_csv(image_csv, "image_id", {images[0].image_id: {"source_group": "session-1", "source_group_status": "verified", "source_group_reason": "verified recording id", "completeness_status": "incomplete"}})
    plan = build_review_plan(images, box_csv, image_csv)
    assert not plan.eligible
    assert "incomplete" in plan.review_queue[0][1]


def test_needs_correction_uses_separate_reviewed_coordinates(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(images, box_csv, image_csv)
    corrected = '{"format":"xyxy_pixel","xyxy":[12,10,48,46]}'
    _edit_csv(box_csv, "box_id", {images[0].boxes[0].box_id: {"review_status": "needs_correction", "review_reason": "tighten left edge", "corrected_bbox": corrected}})
    _edit_csv(box_csv, "box_id", {images[0].boxes[1].box_id: {"review_status": "approved"}})
    _edit_csv(image_csv, "image_id", {images[0].image_id: {"source_group": "session-verified", "source_group_status": "verified", "source_group_reason": "verified source sequence", "completeness_status": "complete", "completeness_reason": "all three target classes checked"}})
    plan = build_review_plan(images, box_csv, image_csv)
    assert len(plan.eligible) == 1
    assert plan.eligible[0].labels[0][1] == (12.0, 10.0, 48.0, 46.0)


def test_unreviewed_negative_does_not_become_empty_training_label(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    images[0] = images[0].__class__(**{**images[0].__dict__, "boxes": ()})
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(images, box_csv, image_csv)
    plan = build_review_plan(images, box_csv, image_csv)
    assert not plan.eligible
    assert plan.review_queue


def test_source_group_split_is_deterministic_and_never_leaks_group(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source, count=6)
    images = parse_cvat_archive(source)
    reviewed = [type("Reviewed", (), {"source_group": f"group-{index}"})() for index in range(6)]
    first = assign_group_splits(reviewed, seed=7)
    second = assign_group_splits(reviewed, seed=7)
    assert first == second
    assert set(first.values()) == {"train", "val", "test"}
    assert len(assign_group_splits(reviewed)) == 6
    with pytest.raises(PreparationError, match="At least three"):
        assign_group_splits(reviewed[:2])


def test_augmentation_candidate_is_excluded_from_validation_and_test(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source, count=4)
    parsed = parse_cvat_archive(source)
    groups = ["verified-train", "verified-val", "verified-test"]
    split_map = assign_group_splits([SimpleNamespace(source_group=group) for group in groups])
    held_out_group = next(group for group, split in split_map.items() if split in {"val", "test"})
    candidates = [replace(parsed[0], source_group=groups[0]), replace(parsed[1], source_group=groups[1]), replace(parsed[2], source_group=groups[2]), replace(parsed[3], source_group=held_out_group, is_augmented=True)]
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(candidates, box_csv, image_csv)
    _edit_csv(box_csv, "box_id", {box.box_id: {"review_status": "approved"} for image in candidates for box in image.boxes})
    _edit_csv(image_csv, "image_id", {
        image.image_id: {
            "source_group": image.source_group,
            "source_group_status": "verified",
            "source_group_reason": "session identity checked",
            "completeness_status": "complete",
            "completeness_reason": "all target classes checked",
        }
        for image in candidates
    })
    output = tmp_path / "prepared"
    mapping = Path(__file__).parents[1] / "class_mapping_3class.json"
    result = convert_reviewed_dataset(candidates, box_csv, image_csv, output, max_images=4, mapping_path=mapping, apply=True)
    assert result.converted_images == 3
    assert result.split_counts == {"train": 1, "val": 1, "test": 1}
    with (output / "dataset_manifest.csv").open(encoding="utf-8-sig", newline="") as stream:
        source_images = {row["source_image"] for row in csv.DictReader(stream)}
    assert candidates[3].source_image not in source_images


def test_dry_run_does_not_create_files(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    output = tmp_path / "derived"
    report = dry_run_summary(images)
    assert report["files_written"] == 0
    assert report["source_archives_modified"] is False
    assert not output.exists()
    assert not list(tmp_path.glob("*.csv"))


def test_approved_three_image_sample_converts_and_existing_validator_accepts_it(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source, count=3)
    images = parse_cvat_archive(source)
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(images, box_csv, image_csv)
    box_updates = {box.box_id: {"review_status": "approved"} for image in images for box in image.boxes}
    image_updates = {
        image.image_id: {
            "source_group": f"verified-session-{index}",
            "source_group_status": "verified",
            "source_group_reason": "same capture sequence confirmed",
            "completeness_status": "complete",
            "completeness_reason": "Human checked all three target classes in full image.",
        }
        for index, image in enumerate(images)
    }
    _edit_csv(box_csv, "box_id", box_updates)
    _edit_csv(image_csv, "image_id", image_updates)
    output = tmp_path / "prepared"
    mapping = Path(__file__).parents[1] / "class_mapping_3class.json"
    result = convert_reviewed_dataset(images, box_csv, image_csv, output, max_images=3, mapping_path=mapping, apply=True)
    assert result.converted_images == 3
    assert result.converted_boxes == 6
    assert result.split_counts == {"train": 1, "val": 1, "test": 1}
    assert (output / "dataset_manifest.csv").is_file()
    assert all((output / "labels" / split).is_dir() for split in ("train", "val", "test"))


def test_approved_review_cannot_silently_change_original_bbox(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(images, box_csv, image_csv)
    _edit_csv(box_csv, "box_id", {images[0].boxes[0].box_id: {"review_status": "approved", "bbox": '{"format":"xyxy_pixel","xyxy":[12,10,48,46]}'}})
    _edit_csv(image_csv, "image_id", {images[0].image_id: {"source_group": "session-verified", "source_group_status": "verified", "source_group_reason": "verified source sequence", "completeness_status": "complete", "completeness_reason": "all three target classes checked"}})
    with pytest.raises(PreparationError, match="use needs_correction"):
        build_review_plan(images, box_csv, image_csv)


def test_stale_or_mismatched_review_manifest_cannot_be_applied(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    images = parse_cvat_archive(source)
    box_csv, image_csv = tmp_path / "box.csv", tmp_path / "image.csv"
    write_review_manifests(images, box_csv, image_csv)
    _edit_csv(image_csv, "image_id", {images[0].image_id: {"source_image": "different.jpg"}})
    with pytest.raises(PreparationError, match="identity fields changed"):
        build_review_plan(images, box_csv, image_csv)


def test_cli_default_dry_run_writes_nothing(tmp_path: Path) -> None:
    source = tmp_path / "aihub.zip"
    _write_cvat_zip(source)
    assert prepare_main(["--aihub-zip", str(source)]) == 0
    assert sorted(path.name for path in tmp_path.iterdir()) == ["aihub.zip"]
