"""공개 버스 문 데이터셋 클래스 병합 변환 테스트."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from prepare_public_bus_door_dataset import prepare_dataset  # noqa: E402


class PreparePublicBusDoorDatasetTest(unittest.TestCase):
    def _make_source(self, root: Path) -> None:
        for split in ("train", "valid", "test"):
            images = root / split / "images"
            labels = root / split / "labels"
            images.mkdir(parents=True)
            labels.mkdir(parents=True)
            (images / "frame.jpg").write_bytes(b"image")
            (labels / "frame.txt").write_text(
                "0 0.5 0.5 0.8 0.5\n1 0.2 0.5 0.1 0.4\n2 0.3 0.2 0.1 0.1\n3 0.8 0.5 0.1 0.4\n",
                encoding="utf-8",
            )

    def test_merges_both_doors_and_drops_number(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            target = root / "target"
            self._make_source(source)

            report = prepare_dataset(source, target)

            self.assertEqual(report.images, 3)
            self.assertEqual(report.kept_labels, 9)
            self.assertEqual(report.removed_number_labels, 3)
            labels = (target / "train" / "labels" / "frame.txt").read_text(encoding="utf-8").splitlines()
            self.assertEqual(labels, ["0 0.5 0.5 0.8 0.5", "1 0.2 0.5 0.1 0.4", "1 0.8 0.5 0.1 0.4"])
            self.assertIn("1: bus_door", (target / "data.yaml").read_text(encoding="utf-8"))

    def test_preserves_source_when_target_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            target = root / "target"
            self._make_source(source)
            target.mkdir()

            with self.assertRaises(FileExistsError):
                prepare_dataset(source, target)


if __name__ == "__main__":
    unittest.main()
