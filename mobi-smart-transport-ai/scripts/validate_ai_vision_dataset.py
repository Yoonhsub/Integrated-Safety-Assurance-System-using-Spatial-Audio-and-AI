"""Validate an Ultralytics YOLO dataset before training or evaluation."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ai_vision.training.dataset_validation import (  # noqa: E402
    DEFAULT_DATA_YAML,
    DatasetReport,
    validate_dataset,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check image/label pairs, YOLO boxes, class IDs, and split leakage."
    )
    parser.add_argument(
        "--data",
        type=Path,
        default=DEFAULT_DATA_YAML,
        help="Ultralytics dataset YAML (default: %(default)s).",
    )
    return parser


def format_report(report: DatasetReport) -> str:
    lines = [
        f"total images: {report.total_images}",
        f"total labels: {report.total_labels}",
        "split counts:",
    ]
    lines.extend(
        f"  {split}: {report.split_images[split]} images, {report.split_labels[split]} labels"
        for split in ("train", "val", "test")
    )
    lines.append("class distribution:")
    lines.extend(f"  {name}: {count}" for name, count in report.class_counts.items())
    lines.append("warnings:")
    lines.extend(f"  - {issue.message}" for issue in report.warnings)
    lines.append("errors:")
    lines.extend(f"  - {issue.message}" for issue in report.errors)
    if not report.errors:
        lines.append("  none")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    report = validate_dataset(args.data)
    print(format_report(report))
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
