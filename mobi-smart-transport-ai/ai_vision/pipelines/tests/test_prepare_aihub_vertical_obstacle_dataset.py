"""AI Hub Column & Tree JSON 변환기의 단위 테스트."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from prepare_aihub_vertical_obstacle_dataset import collect_matching_annotations, prepare_dataset  # noqa: E402


def _payload(file_name: str) -> dict[str, object]:
    return {
        "images": {"file_name": file_name, "width": 100, "height": 50, "id": 1},
        "categories": [
            {"id": 1, "name": "Column & Tree"},
            {"id": 2, "name": "Traffic Signs"},
        ],
        "annotations": [
            {"category_id": 1, "bbox": [10, 5, 20, 30]},
            {"category_id": 2, "bbox": [1, 1, 10, 10]},
        ],
    }


class PrepareAihubVerticalObstacleDatasetTest(unittest.TestCase):
    def test_uses_only_matching_images_and_column_tree_labels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            images, annotations, target = root / "images", root / "annotations", root / "target"
            images.mkdir()
            annotations.mkdir()
            (images / "matched.png").write_bytes(b"placeholder")
            (annotations / "matched_BBOX.json").write_text(json.dumps(_payload("matched.png")), encoding="utf-8")
            (annotations / "missing_BBOX.json").write_text(json.dumps(_payload("missing.png")), encoding="utf-8")

            records, missing_images = collect_matching_annotations(images, annotations)
            report = prepare_dataset(images, annotations, target)

            self.assertEqual(len(records), 1)
            self.assertEqual(records[0].boxes, ((10.0, 5.0, 20.0, 30.0),))
            self.assertEqual(missing_images, 1)
            self.assertEqual(report["missing_json_images"], 1)
            label_paths = list(target.glob("**/labels/matched.txt"))
            self.assertEqual(len(label_paths), 1)
            self.assertEqual(label_paths[0].read_text(encoding="utf-8"), "0 0.20000000 0.40000000 0.20000000 0.60000000\n")


if __name__ == "__main__":
    unittest.main()
