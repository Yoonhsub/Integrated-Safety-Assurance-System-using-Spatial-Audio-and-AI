"""AI Hub 인도보행 XML 변환기의 단위 테스트."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from prepare_aihub_sidewalk_obstacle_dataset import collect_frames, prepare_dataset  # noqa: E402


def _xml(image_name: str, label: str) -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<annotations><image id="0" name="{image_name}" width="100" height="50">
<box label="{label}" xtl="10" ytl="5" xbr="30" ybr="35"/>
<box label="car" xtl="1" ytl="1" xbr="5" ybr="5"/>
</image></annotations>'''


class PrepareAihubSidewalkObstacleDatasetTest(unittest.TestCase):
    def test_keeps_target_classes_and_splits_by_xml_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for number, label in enumerate(("pole", "tree_trunk", "stop"), start=1):
                folder = root / f"Bbox_{number:04d}"
                folder.mkdir()
                image_name = f"frame_{number}.jpg"
                (folder / image_name).write_bytes(b"placeholder")
                (folder / "sequence.xml").write_text(_xml(image_name, label), encoding="utf-8")

            frames, report = collect_frames(root)
            target = root / "converted"
            result = prepare_dataset(root, target)

            self.assertEqual(len(frames), 3)
            self.assertEqual(report["pole_boxes"], 1)
            self.assertEqual(report["tree_trunk_boxes"], 1)
            self.assertEqual(report["stop_boxes"], 1)
            self.assertEqual(result["train_frames"] + result["val_frames"] + result["test_frames"], 3)
            labels = list(target.glob("**/labels/*.txt"))
            self.assertEqual(len(labels), 3)
            self.assertTrue(any(label.read_text(encoding="utf-8").startswith("0 ") for label in labels))
            self.assertTrue(any(label.read_text(encoding="utf-8").startswith("1 ") for label in labels))
            self.assertTrue(any(label.read_text(encoding="utf-8").startswith("2 ") for label in labels))


if __name__ == "__main__":
    unittest.main()
