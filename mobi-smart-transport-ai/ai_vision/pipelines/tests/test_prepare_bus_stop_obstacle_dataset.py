"""정류장·킥보드 export 병합 테스트."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from prepare_bus_stop_obstacle_dataset import prepare_dataset  # noqa: E402


class PrepareBusStopObstacleDatasetTest(unittest.TestCase):
    def _make_source(self, root: Path, label: str) -> None:
        for split in ("train", "valid", "test"):
            images = root / split / "images"
            labels = root / split / "labels"
            images.mkdir(parents=True)
            labels.mkdir(parents=True)
            (images / "frame.jpg").write_bytes(b"image")
            (labels / "frame.txt").write_text(label, encoding="utf-8")

    def test_converts_segmentation_and_maps_kickboard_to_parked_pm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bus_stop = root / "bus_stop"
            kickboard = root / "kickboard"
            target = root / "target"
            self._make_source(
                bus_stop,
                # bus_stop polygon, sidewalk_pole detection, and excluded trash_bin
                "0 0.1 0.2 0.5 0.2 0.5 0.8 0.1 0.8\n2 0.6 0.5 0.1 0.8\n3 0.5 0.5 0.2 0.2\n",
            )
            self._make_source(kickboard, "0 0.3 0.5 0.2 0.6\n")

            report = prepare_dataset(bus_stop, kickboard, target)

            self.assertEqual(report.images, 6)
            self.assertEqual(report.labels_per_class, {0: 3, 1: 3, 3: 3})
            self.assertEqual(report.dropped_trash_bin_labels, 3)
            labels = (target / "train" / "labels" / "busstop_frame.txt").read_text(encoding="utf-8").splitlines()
            self.assertEqual(labels, ["0 0.3 0.5 0.4 0.6000000000000001", "1 0.6 0.5 0.1 0.8"])
            self.assertIn("3: parked_pm", (target / "data.yaml").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
