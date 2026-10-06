from __future__ import annotations

from pathlib import Path

import pytest

from ai_vision.training.dataset_validation import (
    DEFAULT_MAPPING,
    DEFAULT_TAXONOMY,
    load_training_classes,
    parse_label_text,
    validate_dataset,
    validate_dataset_config,
)
from scripts.evaluate_ai_vision_yolo import build_parser as build_evaluation_parser
from scripts.evaluate_ai_vision_yolo import validate_evaluation_args
from scripts.train_ai_vision_yolo import build_parser as build_training_parser
from scripts.train_ai_vision_yolo import validate_training_args


def _write_dataset(root: Path, data_yaml: Path) -> None:
    for split in ("train", "val", "test"):
        images = root / "images" / split
        labels = root / "labels" / split
        images.mkdir(parents=True)
        labels.mkdir(parents=True)
        (images / f"{split}.jpg").write_bytes(f"image:{split}".encode())
        (labels / f"{split}.txt").write_text("", encoding="utf-8")
    data_yaml.write_text(
        "path: dataset\n"
        "train: images/train\n"
        "val: images/val\n"
        "test: images/test\n"
        "names:\n"
        "  0: bus\n"
        "  1: bus_door\n"
        "  2: bus_stop\n"
        "  3: obstacle\n",
        encoding="utf-8",
    )


def test_dataset_yaml_names_match_taxonomy_subset(tmp_path: Path) -> None:
    classes = load_training_classes(DEFAULT_MAPPING, DEFAULT_TAXONOMY)
    assert [(item.yolo_id, item.taxonomy_id, item.name) for item in classes] == [
        (0, "bus", "bus"),
        (1, "bus_door", "bus_door"),
        (2, "bus_stop", "bus_stop"),
        (3, "obstacle", "obstacle"),
    ]
    root = tmp_path / "dataset"
    root.mkdir()
    data_yaml = tmp_path / "data.yaml"
    _write_dataset(root, data_yaml)
    config, resolved_root, _ = validate_dataset_config(data_yaml)
    assert config["names"][0] == "bus"
    assert resolved_root == root.resolve()


def test_dataset_yaml_rejects_mapping_mismatch(tmp_path: Path) -> None:
    root = tmp_path / "dataset"
    root.mkdir()
    data_yaml = tmp_path / "data.yaml"
    _write_dataset(root, data_yaml)
    data_yaml.write_text(data_yaml.read_text(encoding="utf-8").replace("1: bus_door", "1: obstacle"), encoding="utf-8")
    with pytest.raises(ValueError, match="do not match class_mapping"):
        validate_dataset_config(data_yaml)


def test_valid_label_and_empty_negative_label_are_accepted() -> None:
    assert parse_label_text("0 0.5 0.5 0.2 0.4\n3 0.4 0.5 0.2 0.2", 4) == [0, 3]
    assert parse_label_text("", 4) == []


@pytest.mark.parametrize(
    ("line", "message"),
    [
        ("4 0.5 0.5 0.1 0.1", "class ID 4"),
        ("0 1.1 0.5 0.1 0.1", "center"),
        ("0 0.5 0.5 0 0.1", "width and height"),
        ("0 0.5 0.5 1.2 0.1", "width and height"),
        ("0 0.9 0.5 0.4 0.1", "outside image bounds"),
        ("0 0.5 0.5 nan 0.1", "finite numbers"),
        ("0 0.5 0.5 0.1", "expected 5"),
    ],
)
def test_invalid_yolo_label_is_rejected(line: str, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        parse_label_text(line, 4)


def test_report_pairs_labels_and_summarizes_classes(tmp_path: Path) -> None:
    root = tmp_path / "dataset"
    data_yaml = tmp_path / "data.yaml"
    _write_dataset(root, data_yaml)
    (root / "labels/train/train.txt").write_text("0 0.5 0.5 0.2 0.2\n3 0.4 0.4 0.1 0.1\n", encoding="utf-8")
    report = validate_dataset(data_yaml)
    assert not report.errors
    assert report.total_images == 3
    assert report.total_labels == 2
    assert report.split_images == {"train": 1, "val": 1, "test": 1}
    assert report.class_counts == {"bus": 1, "bus_door": 0, "bus_stop": 0, "obstacle": 1}
    assert any("manifest.csv is absent" in issue.message for issue in report.warnings)


def test_report_detects_missing_and_orphan_labels(tmp_path: Path) -> None:
    root = tmp_path / "dataset"
    data_yaml = tmp_path / "data.yaml"
    _write_dataset(root, data_yaml)
    (root / "labels/train/train.txt").unlink()
    (root / "labels/train/orphan.txt").write_text("", encoding="utf-8")
    report = validate_dataset(data_yaml)
    assert any("Missing label file" in issue.message for issue in report.errors)
    assert any("Orphan label" in issue.message for issue in report.errors)


def test_report_detects_duplicate_files_across_splits(tmp_path: Path) -> None:
    root = tmp_path / "dataset"
    data_yaml = tmp_path / "data.yaml"
    _write_dataset(root, data_yaml)
    (root / "images/val/val.jpg").write_bytes((root / "images/train/train.jpg").read_bytes())
    report = validate_dataset(data_yaml)
    assert any("Byte-identical images occur across splits" in issue.message for issue in report.errors)


def test_report_detects_source_group_split_leakage(tmp_path: Path) -> None:
    root = tmp_path / "dataset"
    data_yaml = tmp_path / "data.yaml"
    _write_dataset(root, data_yaml)
    (root / "dataset_manifest.csv").write_text(
        "image,split,source_group\n"
        "images/train/train.jpg,train,recording-1\n"
        "images/val/val.jpg,val,recording-1\n",
        encoding="utf-8",
    )
    report = validate_dataset(data_yaml)
    assert any("leaks across dataset splits" in issue.message for issue in report.errors)


def test_training_cli_argument_validation() -> None:
    args = build_training_parser().parse_args(["--epochs", "2", "--batch", "1"])
    assert validate_training_args(args) == []
    with pytest.raises(SystemExit):
        build_training_parser().parse_args(["--epochs", "0"])


def test_evaluation_cli_argument_validation(tmp_path: Path) -> None:
    weight = tmp_path / "best.pt"
    data = tmp_path / "data.yaml"
    weight.write_bytes(b"stub")
    data.write_text("names: [bus]\n", encoding="utf-8")
    args = build_evaluation_parser().parse_args(["--model", str(weight), "--data", str(data)])
    assert args.split == "test"
    assert validate_evaluation_args(args) == []
    args.model = tmp_path / "missing.pt"
    assert any("weight does not exist" in error for error in validate_evaluation_args(args))
