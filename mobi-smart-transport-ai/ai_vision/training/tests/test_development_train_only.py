from __future__ import annotations

import csv
import hashlib
import io
import json
import zipfile
from pathlib import Path

import pytest
from PIL import Image

from ai_vision.training.dataset_preparation import (
    ADDITIONAL_ANNOTATION_FIELDS,
    PreparationError,
    build_development_train_only_plan,
    convert_development_train_only_dataset,
    parse_cvat_archive,
    write_additional_annotation_template,
    write_review_manifests,
)
from ai_vision.training.dataset_validation import (
    DEFAULT_MAPPING,
    DEFAULT_TAXONOMY,
    load_training_classes,
    validate_development_train_only_dataset,
)


def _write_rows(path: Path, fields: tuple[str, ...], rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def _payload(color: tuple[int, int, int]) -> bytes:
    image = Image.new("RGB", (120, 90), color)
    stream = io.BytesIO()
    image.save(stream, format="JPEG")
    return stream.getvalue()


def _fixture(tmp_path: Path, *, bus_bbox=(3, 4, 60, 70)):
    tmp_path.mkdir(parents=True, exist_ok=True)
    source = tmp_path / "tiny.zip"
    with zipfile.ZipFile(source, "w") as archive:
        nodes = []
        for index, color in enumerate(((20, 30, 40), (50, 60, 70), (80, 90, 100))):
            name = f"frame_{index}.jpg"
            archive.writestr(f"data/{name}", _payload(color))
            nodes.append(
                f'<image id="{index}" name="{name}" width="120" height="90">'
                f'<box label="bus" xtl="{bus_bbox[0]}" ytl="{bus_bbox[1]}" xbr="{bus_bbox[2]}" ybr="{bus_bbox[3]}"/>'
                '<box label="stop" xtl="70" ytl="10" xbr="115" ybr="80"/>'
                '</image>'
            )
        archive.writestr("data/task.xml", "<annotations><meta><task><name>candidate</name></task></meta>" + "".join(nodes) + "</annotations>")
    images = parse_cvat_archive(source)
    box_csv, image_csv = tmp_path / "box_review.csv", tmp_path / "image_review.csv"
    write_review_manifests(images, box_csv, image_csv)
    with box_csv.open(encoding="utf-8-sig", newline="") as stream:
        boxes = list(csv.DictReader(stream))
        box_fields = list(boxes[0])
    for row in boxes:
        row["review_status"] = "approved"
        row["review_reason"] = "reviewed in development fixture"
    _write_rows(box_csv, tuple(box_fields), boxes)
    with image_csv.open(encoding="utf-8-sig", newline="") as stream:
        image_rows = list(csv.DictReader(stream))
        image_fields = list(image_rows[0])
    for row in image_rows:
        row["source_group_status"] = "unverified"
        row["source_group_reason"] = "capture session not confirmed"
        row["completeness_status"] = "complete"
        row["completeness_reason"] = "all target classes checked in full frame"
    _write_rows(image_csv, tuple(image_fields), image_rows)
    checklist = tmp_path / "image_completeness_checklist.csv"
    checklist_fields = ["image_id", "source_dataset", "source_image", "contains_bus", "bus_annotation_complete", "contains_bus_door", "bus_door_annotation_complete", "contains_bus_stop", "bus_stop_annotation_complete"]
    with checklist.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=checklist_fields)
        writer.writeheader()
        for image in images:
            writer.writerow({"image_id": image.image_id, "source_dataset": image.source_dataset, "source_image": image.source_image, "contains_bus": "yes", "bus_annotation_complete": "yes", "contains_bus_door": "no", "bus_door_annotation_complete": "yes", "contains_bus_stop": "yes", "bus_stop_annotation_complete": "yes"})
    additional = tmp_path / "additional_annotations.csv"
    write_additional_annotation_template(additional)
    return source, images, box_csv, image_csv, checklist, additional


def _set_box_review(path: Path, box_id: str, **updates: str) -> None:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
        fields = tuple(rows[0])
    next(row for row in rows if row["box_id"] == box_id).update(updates)
    _write_rows(path, fields, rows)


def test_approved_correction_is_used_in_actual_development_labels(tmp_path: Path) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    corrected = {"format": "xyxy_pixel", "xyxy": [12, 9, 120, 81]}
    _set_box_review(boxes, images[0].boxes[0].box_id, corrected_bbox=json.dumps(corrected))
    output = tmp_path / "corrected"
    result = convert_development_train_only_dataset(
        images, boxes, image_review, checklist, additional, output,
        max_images=3, mapping_path=Path(__file__).parents[1] / "class_mapping_3class.json", apply=True,
    )
    assert result.converted_images == 3
    label = output / "labels/train" / f"{images[0].image_id[:20]}.txt"
    values = list(map(float, label.read_text().splitlines()[0].split()))
    assert values == pytest.approx([0, .55, .5, .9, .8])
    assert not validate_development_train_only_dataset(
        output / "data.yaml", mapping_path=Path(__file__).parents[1] / "class_mapping_3class.json"
    ).errors


def test_approved_without_correction_preserves_original_and_rejected_is_omitted(tmp_path: Path) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert plan.eligible[0].labels[0][1] == images[0].boxes[0].bbox
    _set_box_review(boxes, images[0].boxes[1].box_id, review_status="rejected",
                    review_reason="not a bus stop", corrected_bbox="invalid ignored correction")
    # The absent class must also be explicitly reviewed at image level.
    with checklist.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
        fields = tuple(rows[0])
    next(row for row in rows if row["image_id"] == images[0].image_id)["contains_bus_stop"] = "no"
    _write_rows(checklist, fields, rows)
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert not plan.review_queue
    assert len(plan.eligible[0].labels) == 1
    assert plan.eligible[0].labels[0][0] == "bus"


@pytest.mark.parametrize("correction", [
    "not JSON", "{}", "null", '[]',
    '{"format":"xyxy_normalized","xyxy":[0.1,0.2,0.3]}',
    '{"format":"xyxy_pixel","xyxy":[12,9,12,81]}',
    '{"format":"xyxy_pixel","xyxy":[-1,9,60,81]}',
    '{"format":"xyxy_pixel","xyxy":[12,9,NaN,81]}',
    '{"format":"xyxy_normalized","xyxy":[0.1,0.1,1.1,0.9]}',
    '{"format":"unsupported","xyxy":[12,9,60,81]}',
])
def test_invalid_approved_correction_fails_without_original_fallback(tmp_path: Path, correction: str) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    _set_box_review(boxes, images[0].boxes[0].box_id, corrected_bbox=correction)
    with pytest.raises(PreparationError, match="Invalid reviewed bbox"):
        build_development_train_only_plan(images, boxes, image_review, checklist, additional)


@pytest.mark.parametrize("xyxy", [[12,9,121,81], [12,9,120,91]])
def test_corrected_pixel_bbox_uses_actual_image_bounds_and_rolls_back(tmp_path: Path, xyxy: list[int]) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    _set_box_review(boxes, images[0].boxes[0].box_id,
                    corrected_bbox=json.dumps({"format":"xyxy_pixel","xyxy":xyxy}))
    output = tmp_path / "invalid"
    with pytest.raises((PreparationError, ValueError), match="bounds"):
        convert_development_train_only_dataset(
            images, boxes, image_review, checklist, additional, output,
            max_images=3, mapping_path=Path(__file__).parents[1] / "class_mapping_3class.json", apply=True,
        )
    assert not output.exists()


@pytest.mark.parametrize("status", ["unreviewed", "uncertain", "needs_correction"])
def test_unapproved_corrections_block_development_conversion(tmp_path: Path, status: str) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    _set_box_review(boxes, images[0].boxes[0].box_id, review_status=status,
                    review_reason="await final decision",
                    corrected_bbox='{"format":"xyxy_pixel","xyxy":[12,9,120,81]}')
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert any(image_id == images[0].image_id for image_id, _ in plan.review_queue)
    assert all(item.candidate.image_id != images[0].image_id for item in plan.eligible)


def test_development_train_only_converts_only_train_preserves_unverified_groups_and_validates(tmp_path: Path) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert len(plan.eligible) == 3
    assert not plan.review_queue
    assert {item.source_group_status for item in plan.eligible} == {"unverified"}
    output = tmp_path / "dev_train"
    mapping = Path(__file__).parents[1] / "class_mapping_3class.json"
    result = convert_development_train_only_dataset(
        images, boxes, image_review, checklist, additional, output,
        max_images=3, mapping_path=mapping, apply=True,
    )
    assert result.converted_images == 3
    assert result.converted_boxes == 6
    assert result.split_counts == {"train": 3, "val": 0, "test": 0}
    assert len(list((output / "images/train").glob("*.jpg"))) == 3
    assert len(list((output / "labels/train").glob("*.txt"))) == 3
    assert not (output / "images/val").exists()
    assert not (output / "labels/test").exists()
    report = json.loads((output / "conversion_report.json").read_text(encoding="utf-8"))
    assert report["dataset_mode"] == "development_train_only"
    assert report["evaluation_eligible"] is False
    assert report["source_group_status_counts"] == {"unverified": 3}
    validation = validate_development_train_only_dataset(output / "data.yaml", mapping_path=mapping)
    assert not validation.errors
    assert validation.total_images == 3
    assert validation.class_counts == {"bus": 3, "bus_door": 0, "bus_stop": 3}
    assert len(load_training_classes(DEFAULT_MAPPING, DEFAULT_TAXONOMY)) == 4


def test_development_conversion_preserves_image_edge_bbox_precision(tmp_path: Path) -> None:
    from ai_vision.training.dataset_validation import parse_label_text

    _, images, boxes, image_review, checklist, additional = _fixture(
        tmp_path, bus_bbox=(10, 4, 120, 70),
    )
    # Eight decimal places push this valid right-edge box outside the image.
    with pytest.raises(ValueError, match="outside image bounds"):
        parse_label_text("0 0.54166667 0.41111111 0.91666667 0.73333333", 3)
    output = tmp_path / "edge_train"
    mapping = Path(__file__).parents[1] / "class_mapping_3class.json"
    result = convert_development_train_only_dataset(
        images, boxes, image_review, checklist, additional, output,
        max_images=3, mapping_path=mapping, apply=True,
    )
    assert result.converted_images == 3
    for label in (output / "labels/train").glob("*.txt"):
        values = [float(value) for value in label.read_text().splitlines()[0].split()[1:]]
        assert values[0] + values[2] / 2 == pytest.approx(1, abs=1e-12)
    validation = validate_development_train_only_dataset(output / "data.yaml", mapping_path=mapping)
    assert not validation.errors


def test_development_mode_blocks_uncertain_checklist_and_unapproved_bbox(tmp_path: Path) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    with checklist.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
        fields = list(rows[0])
    rows[0]["contains_bus_stop"] = "uncertain"
    rows[0]["bus_stop_annotation_complete"] = "uncertain"
    _write_rows(checklist, tuple(fields), rows)
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert any("bus_stop presence/completeness" in reason for _, reason in plan.review_queue)
    output = tmp_path / "must_not_write"
    with pytest.raises(PreparationError, match="review item"):
        convert_development_train_only_dataset(
            images, boxes, image_review, checklist, additional, output,
            max_images=3, mapping_path=Path(__file__).parents[1] / "class_mapping_3class.json", apply=True,
        )
    assert not output.exists()

    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path / "second")
    with boxes.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
        fields = list(rows[0])
    rows[0]["review_status"] = "unreviewed"
    rows[0]["review_reason"] = ""
    _write_rows(boxes, tuple(fields), rows)
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert any("must be approved or rejected" in reason for _, reason in plan.review_queue)


def test_development_mode_blocks_source_hash_mismatch_and_duplicate_additional_bbox(tmp_path: Path) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    with image_review.open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
        fields = list(rows[0])
    rows[0]["original_hash"] = "0" * 64
    _write_rows(image_review, tuple(fields), rows)
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert any("original_hash does not match" in reason for _, reason in plan.review_queue)

    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path / "duplicate")
    image = images[0]
    with zipfile.ZipFile(image.archive_path) as archive:
        payload = archive.read(image.archive_member)
    row = {
        "source_dataset": image.source_dataset,
        "image_id": image.image_id,
        "source_image": image.source_image,
        "source_annotation": image.source_annotation,
        "new_box_id": f"additional:{image.image_id[:16]}:0001",
        "target_class": "bus",
        "bbox_coordinates": "[3,4,60,70]",
        "coordinate_format": "xyxy_pixel",
        "review_status": "approved",
        "review_reason": "same as original bus bbox",
        "reviewer": "test-reviewer",
        "reviewed_at": "2026-10-10T12:00:00+09:00",
        "original_hash": hashlib.sha256(payload).hexdigest(),
        "image_width": "120",
        "image_height": "90",
        "corrected_bbox_coordinates": "",
        "source_group": image.source_group,
        "source_license": image.source_license,
        "source_url": image.source_url,
    }
    with additional.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=ADDITIONAL_ANNOTATION_FIELDS)
        writer.writeheader()
        writer.writerow(row)
    plan = build_development_train_only_plan(images, boxes, image_review, checklist, additional)
    assert any("duplicate" in reason for _, reason in plan.review_queue)


def test_development_validator_rejects_evaluation_split_directories(tmp_path: Path) -> None:
    _, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    output = tmp_path / "dev_train"
    convert_development_train_only_dataset(
        images, boxes, image_review, checklist, additional, output,
        max_images=3, mapping_path=Path(__file__).parents[1] / "class_mapping_3class.json", apply=True,
    )
    (output / "images/val").mkdir()
    report = validate_development_train_only_dataset(
        output / "data.yaml", mapping_path=Path(__file__).parents[1] / "class_mapping_3class.json",
    )
    assert any("must not contain val directories" in issue.message for issue in report.errors)


def test_development_cli_dry_run_writes_nothing(tmp_path: Path, capsys) -> None:
    from scripts.prepare_ai_vision_dataset import main

    source, images, boxes, image_review, checklist, additional = _fixture(tmp_path)
    selection = tmp_path / "selection.csv"
    with selection.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=["image_id"])
        writer.writeheader()
        for image in images:
            writer.writerow({"image_id": image.image_id})
    output = tmp_path / "dry-run-output"
    code = main([
        "--aihub-zip", str(source),
        "--image-ids-csv", str(selection),
        "--box-review-csv", str(boxes),
        "--image-review-csv", str(image_review),
        "--image-completeness-checklist-csv", str(checklist),
        "--additional-annotations-csv", str(additional),
        "--development-train-only",
        "--output", str(output),
    ])
    summary = json.loads(capsys.readouterr().out)
    assert code == 0
    assert summary["development_train_only"]["evaluation_eligible"] is False
    assert summary["development_train_only"]["review_queue_items"] == 0
    assert summary["files_written"] == 0
    assert not output.exists()
