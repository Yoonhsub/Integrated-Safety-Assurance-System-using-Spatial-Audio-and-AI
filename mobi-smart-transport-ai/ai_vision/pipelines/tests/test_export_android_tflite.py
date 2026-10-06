"""TFLite export helper의 파일 선택·입력 검증 테스트."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
_FIXTURES_DIR = _PIPELINES_DIR / "fixtures" / "tflite_export"
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from export_android_tflite import find_tflite_artifact  # noqa: E402


class ExportAndroidTfliteTest(unittest.TestCase):
    def test_finds_single_tflite_artifact_recursively(self) -> None:
        root = _FIXTURES_DIR / "single"
        artifact = root / "saved_model" / "model_float32.tflite"

        self.assertEqual(find_tflite_artifact(root), artifact)

    def test_rejects_missing_or_ambiguous_artifact(self) -> None:
        with self.assertRaises(FileNotFoundError):
            find_tflite_artifact(_FIXTURES_DIR / "missing")

        with self.assertRaises(RuntimeError):
            find_tflite_artifact(_FIXTURES_DIR / "ambiguous")


if __name__ == "__main__":
    unittest.main()
