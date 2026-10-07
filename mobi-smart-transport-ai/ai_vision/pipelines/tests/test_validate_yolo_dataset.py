"""커스텀 YOLO 데이터셋 사전 검증기 테스트."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from validate_yolo_dataset import validate_dataset  # noqa: E402


class ValidateYoloDatasetTest(unittest.TestCase):
    def _create_dataset(self, root: Path, *, label: str) -> Path:
        taxonomy = root / "taxonomy.json"
        taxonomy.write_text(json.dumps({"classes": [{"id": "bus"}, {"id": "bus_door"}]}), encoding="utf-8")
        for split in ("train", "val", "test"):
            (root / split / "images").mkdir(parents=True)
            (root / split / "labels").mkdir(parents=True)
        (root / "train" / "images" / "frame.jpg").write_bytes(b"placeholder")
        (root / "train" / "labels" / "frame.txt").write_text(label, encoding="utf-8")
        return taxonomy

    def test_accepts_well_formed_dataset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            taxonomy = self._create_dataset(root, label="0 0.5 0.5 0.4 0.3\n")
            report = validate_dataset(root, taxonomy_path=taxonomy)
            self.assertTrue(report.valid)
            self.assertEqual(report.image_count, 1)

    def test_reports_invalid_class_and_coordinates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            taxonomy = self._create_dataset(root, label="3 0.5 0.5 0.0 1.2\n")
            report = validate_dataset(root, taxonomy_path=taxonomy)
            self.assertFalse(report.valid)
            self.assertEqual(len(report.errors), 2)

    def test_reports_missing_matching_label(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            taxonomy = self._create_dataset(root, label="0 0.5 0.5 0.4 0.3\n")
            (root / "train" / "labels" / "frame.txt").unlink()
            report = validate_dataset(root, taxonomy_path=taxonomy)
            self.assertFalse(report.valid)
            self.assertIn("missing label for image", report.errors[0])


if __name__ == "__main__":
    unittest.main()
