"""Review-gated AI Vision dataset inspection and conversion CLI."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ai_vision.training.dataset_preparation import (  # noqa: E402
    PreparationError,
    build_review_plan,
    convert_reviewed_dataset,
    create_review_preview,
    create_annotation_workbench,
    dry_run_summary,
    parse_cvat_archive,
    parse_roboflow_archive,
    select_images_by_id,
    write_review_manifests,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inspect source archives and prepare only explicitly reviewed 3-class YOLO data."
    )
    parser.add_argument("--aihub-zip", type=Path, help="AI-Hub archive containing CVAT XML and images.")
    parser.add_argument("--roboflow-zip", type=Path, help="Roboflow YOLOv8 export archive.")
    parser.add_argument("--write-review-dir", type=Path, help="Explicitly write editable image/box CSV review queues.")
    parser.add_argument("--box-review-csv", type=Path, help="Human-edited box review manifest.")
    parser.add_argument("--image-review-csv", type=Path, help="Human-edited image completeness/group manifest.")
    parser.add_argument("--preview-dir", type=Path, help="Explicitly write bbox overlay images here.")
    parser.add_argument("--workbench-dir", type=Path, help="Create a browser annotation workbench for explicitly selected image IDs.")
    parser.add_argument("--image-id", action="append", default=[], help="Image ID to scope review/conversion to; repeat as needed.")
    parser.add_argument("--image-ids-csv", type=Path, help="CSV with an image_id column to scope dry-run/review/conversion to a sample batch.")
    parser.add_argument("--additional-annotations-csv", type=Path, help="Human-reviewed new-box sidecar CSV.")
    parser.add_argument("--box-id", action="append", default=[], help="Box ID to include in previews; repeat as needed.")
    parser.add_argument("--apply", action="store_true", help="Write a derived dataset (requires reviews, output path, and image cap).")
    parser.add_argument("--output", type=Path, help="Derived dataset output directory; must be absent or empty.")
    parser.add_argument("--max-images", type=int, help="Required positive cap for explicit conversion.")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic source-group split seed.")
    return parser


def _load_sources(args: argparse.Namespace):
    images = []
    if args.aihub_zip:
        images.extend(parse_cvat_archive(args.aihub_zip))
    if args.roboflow_zip:
        images.extend(parse_roboflow_archive(args.roboflow_zip))
    return images


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.aihub_zip and not args.roboflow_zip:
        raise SystemExit("Provide at least one source archive.")
    if args.box_id and not args.preview_dir:
        raise SystemExit("--box-id requires --preview-dir.")
    if args.image_id and args.image_ids_csv:
        raise SystemExit("Use either --image-id or --image-ids-csv, not both.")
    if args.workbench_dir and not (args.image_id or args.image_ids_csv):
        raise SystemExit("--workbench-dir requires explicit --image-id values or --image-ids-csv.")
    if args.apply:
        missing = [name for name, value in (
            ("--output", args.output), ("--max-images", args.max_images),
            ("--box-review-csv", args.box_review_csv), ("--image-review-csv", args.image_review_csv),
        ) if value is None]
        if missing:
            raise SystemExit("--apply requires " + ", ".join(missing) + ".")
        if args.max_images <= 0:
            raise SystemExit("--max-images must be positive.")

    try:
        selected_ids = list(args.image_id)
        if args.image_ids_csv:
            with args.image_ids_csv.open(encoding="utf-8-sig", newline="") as stream:
                reader = csv.DictReader(stream)
                if not reader.fieldnames or "image_id" not in reader.fieldnames:
                    raise PreparationError(f"{args.image_ids_csv} must contain an image_id column.")
                selected_ids = [(row.get("image_id") or "").strip() for row in reader]
            if not selected_ids:
                raise PreparationError(f"{args.image_ids_csv} contains no image IDs; refusing to expand to the full source dataset.")
        images = _load_sources(args)
        if selected_ids:
            images = select_images_by_id(images, selected_ids)
        summary = dry_run_summary(images)
        if args.write_review_dir:
            write_review_manifests(
                images,
                args.write_review_dir / "box_review.csv",
                args.write_review_dir / "image_review.csv",
                compute_hashes=True,
            )
            summary["review_manifests_written"] = 2
            summary["review_manifest_dir"] = str(args.write_review_dir.resolve())
        if args.box_review_csv and args.image_review_csv:
            plan = build_review_plan(
                images, args.box_review_csv, args.image_review_csv,
                args.additional_annotations_csv,
            )
            summary["eligible_reviewed_images"] = len(plan.eligible)
            summary["review_queue_items"] = len(plan.review_queue)
            summary["box_review_counts"] = dict(plan.box_counts)
            summary["image_review_counts"] = dict(plan.image_counts)
            summary["additional_annotation_counts"] = {
                key: value for key, value in plan.box_counts.items() if key.startswith("additional_")
            }
        if args.additional_annotations_csv and not (args.box_review_csv and args.image_review_csv):
            raise PreparationError("--additional-annotations-csv requires both review CSVs for dry-run gating.")
        if args.workbench_dir:
            workbench = create_annotation_workbench(images, args.workbench_dir, image_ids=selected_ids)
            summary["workbench_index"] = str(workbench.resolve())
            summary["workbench_images"] = len(selected_ids)
            summary["additional_annotation_template"] = str((args.workbench_dir / "additional_annotations.csv").resolve())
            from ai_vision.training.dataset_preparation import write_additional_annotation_template
            write_additional_annotation_template(args.workbench_dir / "additional_annotations.csv")
        if args.preview_dir:
            wanted = set(args.box_id)
            chosen = [image for image in images if any(box.box_id in wanted for box in image.boxes)]
            if wanted:
                found = {box.box_id for image in chosen for box in image.boxes}
                absent = sorted(wanted - found)
                if absent:
                    raise PreparationError(f"Unknown box ID(s): {absent}")
            elif len(images) != 1:
                raise PreparationError("Use --box-id to select preview samples when more than one image is available.")
            else:
                chosen = images
            output_files = []
            for image in chosen:
                output_files.extend(create_review_preview(image, args.preview_dir))
            summary["previews_written"] = len(output_files)
            summary["preview_files"] = [str(path.resolve()) for path in output_files]
        if args.apply:
            result = convert_reviewed_dataset(
                images, args.box_review_csv, args.image_review_csv, args.output,
                max_images=args.max_images, seed=args.seed,
                mapping_path=ROOT / "ai_vision/training/class_mapping_3class.json",
                additional_annotations=args.additional_annotations_csv,
                apply=True,
            )
            summary["conversion"] = {
                "output_dir": str(result.output_dir),
                "images": result.converted_images,
                "boxes": result.converted_boxes,
                "splits": result.split_counts,
                "validation_errors": result.validation_errors,
            }
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    except (OSError, ValueError, PreparationError, json.JSONDecodeError) as exc:
        print(f"dataset preparation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
