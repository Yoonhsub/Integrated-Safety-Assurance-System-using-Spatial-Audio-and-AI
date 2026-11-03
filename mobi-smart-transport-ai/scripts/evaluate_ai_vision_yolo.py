"""Evaluate explicit local YOLO weights and report aggregate/per-class metrics."""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ai_vision.training.dataset_validation import (  # noqa: E402
    DEFAULT_DATA_YAML,
    validate_dataset,
)
from scripts.validate_ai_vision_dataset import format_report  # noqa: E402


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Evaluate an existing local YOLO weight file on a dataset split."
    )
    parser.add_argument("--model", type=Path, required=True, help="Existing local weight file.")
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA_YAML)
    parser.add_argument("--split", choices=("train", "val", "test"), default="test")
    parser.add_argument("--imgsz", type=_positive_int, default=640)
    parser.add_argument("--batch", type=_positive_int, default=16)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--output", type=Path, help="Optional path for the JSON evaluation report.")
    return parser


def validate_evaluation_args(args: argparse.Namespace) -> list[str]:
    errors: list[str] = []
    if not args.model.is_file():
        errors.append(f"Local model weight does not exist: {args.model}")
    if not args.data.is_file():
        errors.append(f"Dataset YAML does not exist: {args.data}")
    if args.imgsz <= 0 or args.batch <= 0:
        errors.append("--imgsz and --batch must be greater than zero.")
    return errors


def _float_or_none(value: Any) -> float | None:
    if hasattr(value, "item"):
        value = value.item()
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def build_summary(metrics: Any, names: dict[int, str] | list[str]) -> dict[str, Any]:
    box = metrics.box
    summary: dict[str, Any] = {
        "map50": _float_or_none(box.map50),
        "map50_95": _float_or_none(box.map),
        "precision": _float_or_none(box.mp),
        "recall": _float_or_none(box.mr),
        "classes": [],
    }
    class_ids = list(getattr(box, "ap_class_index", []))
    precisions = list(getattr(box, "p", []))
    recalls = list(getattr(box, "r", []))
    ap50 = list(getattr(box, "ap50", []))
    ap = list(getattr(box, "ap", []))
    for row, class_id_value in enumerate(class_ids):
        class_id = int(class_id_value)
        name = names.get(class_id, str(class_id)) if isinstance(names, dict) else names[class_id]
        ap_row = ap[row] if row < len(ap) else None
        if hasattr(ap_row, "tolist"):
            ap_row = ap_row.tolist()
        map_value = None
        if isinstance(ap_row, (list, tuple)) and ap_row:
            finite_values = [value for value in (_float_or_none(item) for item in ap_row) if value is not None]
            map_value = sum(finite_values) / len(finite_values) if finite_values else None
        summary["classes"].append(
            {
                "id": class_id,
                "name": name,
                "precision": _float_or_none(precisions[row]) if row < len(precisions) else None,
                "recall": _float_or_none(recalls[row]) if row < len(recalls) else None,
                "map50": _float_or_none(ap50[row]) if row < len(ap50) else None,
                "map50_95": map_value,
            }
        )
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    argument_errors = validate_evaluation_args(args)
    if argument_errors:
        parser.error(" ".join(argument_errors))

    report = validate_dataset(args.data)
    print(format_report(report))
    if report.errors:
        print("Dataset validation failed; evaluation was not started.", file=sys.stderr)
        return 2

    try:
        from ultralytics import YOLO
    except ImportError:
        print(
            "Ultralytics is not installed. Install ai_vision/requirements.txt before evaluation.",
            file=sys.stderr,
        )
        return 2

    try:
        model = YOLO(str(args.model.resolve()))
        metrics = model.val(
            data=str(args.data.resolve()),
            split=args.split,
            imgsz=args.imgsz,
            batch=args.batch,
            device=args.device,
        )
        names = getattr(metrics, "names", getattr(model, "names", {}))
        summary = build_summary(metrics, names)
        summary["split"] = args.split
        summary["model"] = str(args.model.resolve())
    except Exception as exc:
        print(f"YOLO evaluation failed: {exc}", file=sys.stderr)
        return 1

    rendered = json.dumps(summary, ensure_ascii=False, indent=2, allow_nan=False)
    print(rendered)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
        print(f"Evaluation report: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
