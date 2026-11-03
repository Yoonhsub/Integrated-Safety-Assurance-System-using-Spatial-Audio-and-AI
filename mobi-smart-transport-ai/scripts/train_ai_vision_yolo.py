"""Explicit CLI for fine-tuning a local/custom YOLO model on project data."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
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
        description="Fine-tune YOLO explicitly after validating the local dataset."
    )
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA_YAML)
    parser.add_argument(
        "--model",
        default="yolo11n.pt",
        help="Local weight path or explicit Ultralytics model identifier (default: yolo11n.pt).",
    )
    parser.add_argument("--epochs", type=_positive_int, default=100)
    parser.add_argument("--imgsz", type=_positive_int, default=640)
    parser.add_argument("--batch", type=_positive_int, default=16)
    parser.add_argument(
        "--device",
        default="cpu",
        help="Ultralytics device value, for example cpu or 0; defaults to cpu.",
    )
    parser.add_argument("--project", type=Path, default=ROOT / "ai_vision/training/runs")
    parser.add_argument("--name", default="bus-safety-yolo11n")
    parser.add_argument("--seed", type=int, default=42)
    return parser


def validate_training_args(args: argparse.Namespace) -> list[str]:
    errors: list[str] = []
    for name in ("epochs", "imgsz", "batch"):
        if getattr(args, name) <= 0:
            errors.append(f"--{name} must be greater than zero.")
    if not str(args.model).strip():
        errors.append("--model must not be empty.")
    if not str(args.name).strip():
        errors.append("--name must not be empty.")
    return errors


def _write_run_metadata(args: argparse.Namespace, model: Any, ultralytics_version: str) -> Path:
    trainer = getattr(model, "trainer", None)
    save_dir = Path(getattr(trainer, "save_dir", args.project / args.name))
    data_path = args.data.resolve()
    metadata = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "model": args.model,
        "ultralyticsVersion": ultralytics_version,
        "dataYaml": str(data_path),
        "dataYamlSha256": hashlib.sha256(data_path.read_bytes()).hexdigest(),
        "epochs": args.epochs,
        "imgsz": args.imgsz,
        "batch": args.batch,
        "device": args.device,
        "project": str(args.project),
        "name": args.name,
        "seed": args.seed,
        "deterministic": True,
    }
    save_dir.mkdir(parents=True, exist_ok=True)
    destination = save_dir / "training_metadata.json"
    destination.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    argument_errors = validate_training_args(args)
    if argument_errors:
        parser.error(" ".join(argument_errors))

    report = validate_dataset(args.data)
    print(format_report(report))
    if report.errors:
        print("Dataset validation failed; training was not started.", file=sys.stderr)
        return 2

    try:
        import ultralytics
        from ultralytics import YOLO
    except ImportError as exc:
        print(
            "Ultralytics is not installed. Install ai_vision/requirements.txt before training.",
            file=sys.stderr,
        )
        return 2

    try:
        model = YOLO(args.model)
        model.train(
            data=str(args.data.resolve()),
            epochs=args.epochs,
            imgsz=args.imgsz,
            batch=args.batch,
            device=args.device,
            project=str(args.project),
            name=args.name,
            seed=args.seed,
            deterministic=True,
        )
        metadata_path = _write_run_metadata(args, model, ultralytics.__version__)
    except Exception as exc:
        print(f"YOLO training failed: {exc}", file=sys.stderr)
        return 1
    print(f"Training metadata: {metadata_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
