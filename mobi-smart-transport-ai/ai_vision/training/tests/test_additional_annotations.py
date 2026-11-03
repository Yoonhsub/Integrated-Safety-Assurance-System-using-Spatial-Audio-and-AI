from __future__ import annotations

import csv
import io
import json
import zipfile
from pathlib import Path
from types import SimpleNamespace

import pytest
from PIL import Image

from ai_vision.training.dataset_preparation import (
    ADDITIONAL_ANNOTATION_FIELDS,
    PreparationError,
    assign_group_splits,
    build_review_plan,
    convert_reviewed_dataset,
    create_annotation_workbench,
    parse_cvat_archive,
    select_images_by_id,
    write_additional_annotation_template,
    write_review_manifests,
)
from ai_vision.training.dataset_validation import DEFAULT_MAPPING, DEFAULT_TAXONOMY, load_training_classes


def _jpg(index: int = 0) -> bytes:
    image = Image.new("RGB", (100, 80), (100 + index * 20, 120, 140))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG")
    return buffer.getvalue()


def _archive(path: Path, count: int = 3) -> list[bytes]:
    payloads = [_jpg(index) for index in range(count)]
    nodes = []
    with zipfile.ZipFile(path, "w") as archive:
        for index, payload in enumerate(payloads):
            name = f"frame_{index}.jpg"
            archive.writestr(f"source/{name}", payload)
            nodes.append(
                f'<image id="{index}" name="{name}" width="100" height="80">'
                '<box label="bus" xtl="1" ytl="1" xbr="40" ybr="60"/>'
                '<box label="stop" xtl="50" ytl="5" xbr="90" ybr="70"/>'
                "</image>"
            )
        archive.writestr(
            "source/annotations.xml",
            "<annotations><meta><task><name>fixture</name></task></meta>" + "".join(nodes) + "</annotations>",
        )
    return payloads


def _csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def _write_rows(path: Path, fields: tuple[str, ...], rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def _prepare(tmp_path: Path):
    source = tmp_path / "fixture.zip"
    payloads = _archive(source)
    images = parse_cvat_archive(source)
    boxes, image_review = tmp_path / "box_review.csv", tmp_path / "image_review.csv"
    write_review_manifests(images, boxes, image_review)
    box_rows = _csv_rows(boxes)
    for row in box_rows:
        row["review_status"] = "approved"
    _write_rows(boxes, tuple(box_rows[0]), box_rows)
    image_rows = _csv_rows(image_review)
    for index, row in enumerate(image_rows):
        row.update({
            "source_group": f"verified-capture-{index}",
            "source_group_status": "verified",
            "source_group_reason": "fixture capture identity manually confirmed",
            "completeness_status": "complete",
            "completeness_reason": "all three target classes manually reviewed",
        })
    _write_rows(image_review, tuple(image_rows[0]), image_rows)
    sidecar = tmp_path / "additional_annotations.csv"
    write_additional_annotation_template(sidecar)
    return source, payloads, images, boxes, image_review, sidecar


def _new_box(image, *, status="approved", bbox="[20,20,60,60]", fmt="xyxy_pixel", **updates):
    return {
        "source_dataset": image.source_dataset,
        "image_id": image.image_id,
        "source_image": image.source_image,
        "source_annotation": image.source_annotation,
        "new_box_id": f"additional:{image.image_id[:16]}:0001",
        "target_class": "bus_door",
        "bbox_coordinates": bbox,
        "coordinate_format": fmt,
        "review_status": status,
        "review_reason": "fixture human review" if status == "approved" else "",
        "reviewer": "human-reviewer" if status == "approved" else "",
        "reviewed_at": "2026-10-09T12:00:00+09:00" if status == "approved" else "",
        "original_hash": __import__("hashlib").sha256(_jpg(0)).hexdigest(),
        "image_width": "100",
        "image_height": "80",
        "corrected_bbox_coordinates": "",
        "source_group": image.source_group,
        "source_license": image.source_license,
        "source_url": image.source_url,
        **updates,
    }


def _append_sidecar(path: Path, rows: list[dict[str, str]]) -> None:
    _write_rows(path, ADDITIONAL_ANNOTATION_FIELDS, rows)


def test_sidecar_new_bbox_links_image_hash_dimensions_and_converts_coordinates(tmp_path: Path) -> None:
    _, payloads, images, boxes, image_review, sidecar = _prepare(tmp_path)
    row = _new_box(images[0])
    import hashlib
    row["original_hash"] = hashlib.sha256(payloads[0]).hexdigest()
    _append_sidecar(sidecar, [row])
    plan = build_review_plan(images, boxes, image_review, sidecar)
    approved = next(item for item in plan.eligible if item.candidate.image_id == images[0].image_id)
    assert approved.labels[-1] == ("bus_door", (20.0, 20.0, 60.0, 60.0), "xyxy_pixel")
    assert approved.label_provenance[-1]["annotation_source"] == "additional"
    assert approved.label_provenance[-1]["box_id"] == row["new_box_id"]
    assert approved.label_provenance[-1]["reviewer"] == "human-reviewer"


def test_normalized_sidecar_bbox_uses_source_image_dimensions(tmp_path: Path) -> None:
    _, payloads, images, boxes, image_review, sidecar = _prepare(tmp_path)
    import hashlib
    row = _new_box(images[0], bbox="[0.2,0.25,0.6,0.75]", fmt="xyxy_normalized")
    row["original_hash"] = hashlib.sha256(payloads[0]).hexdigest()
    _append_sidecar(sidecar, [row])
    plan = build_review_plan(images, boxes, image_review, sidecar)
    approved = next(item for item in plan.eligible if item.candidate.image_id == images[0].image_id)
    assert approved.labels[-1] == ("bus_door", (0.2, 0.25, 0.6, 0.75), "xyxy_normalized")


@pytest.mark.parametrize("bbox,fmt", [("[-1,10,50,50]", "xyxy_pixel"), ("[10,10,20,20]", "xyxy_pixel"), ("[0.1,0.1,0.2,0.2]", "unknown")])
def test_new_bbox_rejects_out_of_bounds_too_small_or_unknown_coordinate_format(tmp_path: Path, bbox: str, fmt: str) -> None:
    _, payloads, images, boxes, image_review, sidecar = _prepare(tmp_path)
    row = _new_box(images[0], bbox=bbox, fmt=fmt)
    import hashlib
    row["original_hash"] = hashlib.sha256(payloads[0]).hexdigest()
    _append_sidecar(sidecar, [row])
    with pytest.raises(PreparationError, match="Invalid additional bbox"):
        build_review_plan(images, boxes, image_review, sidecar)


def test_unapproved_additional_bbox_blocks_image_conversion(tmp_path: Path) -> None:
    _, payloads, images, boxes, image_review, sidecar = _prepare(tmp_path)
    row = _new_box(images[0], status="unreviewed")
    import hashlib
    row["original_hash"] = hashlib.sha256(payloads[0]).hexdigest()
    _append_sidecar(sidecar, [row])
    plan = build_review_plan(images, boxes, image_review, sidecar)
    assert not any(item.candidate.image_id == images[0].image_id for item in plan.eligible)
    assert any("explicit approval" in reason for image_id, reason in plan.review_queue if image_id == images[0].image_id)


def test_new_bbox_identity_rejects_wrong_image_hash_and_original_id_collision(tmp_path: Path) -> None:
    _, payloads, images, boxes, image_review, sidecar = _prepare(tmp_path)
    row = _new_box(images[0], original_hash="0" * 64)
    _append_sidecar(sidecar, [row])
    with pytest.raises(PreparationError, match="original_hash mismatch"):
        build_review_plan(images, boxes, image_review, sidecar)
    row = _new_box(images[0], new_box_id=images[0].boxes[0].box_id)
    import hashlib
    row["original_hash"] = hashlib.sha256(payloads[0]).hexdigest()
    _append_sidecar(sidecar, [row])
    with pytest.raises(PreparationError, match="collides"):
        build_review_plan(images, boxes, image_review, sidecar)


def test_completeness_and_source_group_split_gates_remain_required(tmp_path: Path) -> None:
    _, payloads, images, boxes, image_review, sidecar = _prepare(tmp_path)
    import hashlib
    row = _new_box(images[0])
    row["original_hash"] = hashlib.sha256(payloads[0]).hexdigest()
    _append_sidecar(sidecar, [row])
    image_rows = _csv_rows(image_review)
    image_rows[0]["completeness_status"] = "incomplete"
    _write_rows(image_review, tuple(image_rows[0]), image_rows)
    plan = build_review_plan(images, boxes, image_review, sidecar)
    assert not any(item.candidate.image_id == images[0].image_id for item in plan.eligible)
    with pytest.raises(PreparationError, match="source groups"):
        assign_group_splits([SimpleNamespace(source_group="same-session") for _ in range(3)])
    assignments = assign_group_splits([
        SimpleNamespace(source_group="capture-a"), SimpleNamespace(source_group="capture-a"),
        SimpleNamespace(source_group="capture-b"), SimpleNamespace(source_group="capture-c"),
    ])
    assert assignments["capture-a"] in {"train", "val", "test"}


def test_approved_original_and_new_boxes_merge_into_three_class_conversion(tmp_path: Path) -> None:
    _, payloads, images, boxes, image_review, sidecar = _prepare(tmp_path)
    import hashlib
    additions = []
    for image, payload in zip(images, payloads):
        row = _new_box(image)
        row["original_hash"] = hashlib.sha256(payload).hexdigest()
        additions.append(row)
    _append_sidecar(sidecar, additions)
    output = tmp_path / "derived"
    mapping = Path(__file__).parents[1] / "class_mapping_3class.json"
    result = convert_reviewed_dataset(
        images, boxes, image_review, output, max_images=3,
        mapping_path=mapping, additional_annotations=sidecar, apply=True,
    )
    assert result.converted_images == 3
    assert result.converted_boxes == 9
    label_path = next((output / "labels").glob("*/*.txt"))
    rows = label_path.read_text(encoding="utf-8").splitlines()
    assert "1 0.40000000 0.50000000 0.40000000 0.50000000" in rows
    with (output / "dataset_manifest.csv").open(encoding="utf-8-sig", newline="") as stream:
        records = [json.loads(row["target_annotations"]) for row in csv.DictReader(stream)]
    assert all(any(box.get("annotation_source") == "additional" for box in item) for item in records)
    assert len(load_training_classes(DEFAULT_MAPPING, DEFAULT_TAXONOMY)) == 4


def test_workbench_is_explicit_scoped_and_exports_unreviewed_template(tmp_path: Path) -> None:
    source, _, images, *_ = _prepare(tmp_path)
    workbench = tmp_path / "workbench"
    html = create_annotation_workbench(images, workbench, image_ids=[images[0].image_id])
    assert html.is_file()
    html_text = html.read_text(encoding="utf-8")
    assert "const data=[" in html_text
    assert "fetch('workbench.json')" not in html_text
    assert "drawingsByImage" in html_text
    assert "review_status:'unreviewed'" in html_text
    assert (workbench / "images").iterdir()
    template = workbench / "additional_annotations.csv"
    write_additional_annotation_template(template)
    with template.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        assert tuple(reader.fieldnames or ()) == ADDITIONAL_ANNOTATION_FIELDS
        assert list(reader) == []
    with zipfile.ZipFile(source) as archive:
        assert len([name for name in archive.namelist() if name.endswith(".jpg")]) == 3


def test_explicit_sample_selection_rejects_unknown_and_duplicate_image_ids(tmp_path: Path) -> None:
    source = tmp_path / "fixture.zip"
    _archive(source, count=3)
    images = parse_cvat_archive(source)
    assert select_images_by_id(images, [images[1].image_id]) == [images[1]]
    with pytest.raises(PreparationError, match="Unknown image ID"):
        select_images_by_id(images, ["not-a-source-image"])
    with pytest.raises(PreparationError, match="duplicates"):
        select_images_by_id(images, [images[0].image_id, images[0].image_id])
