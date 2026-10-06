"""개발 일정 1주차 Android AI Vision 기준 프로필 검증."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


_PIPELINES_DIR = Path(__file__).resolve().parent.parent
if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))

from android_live_profile import load_android_live_profile  # noqa: E402


class AndroidLiveProfileTest(unittest.TestCase):
    def test_profile_freezes_android_camera_model_and_contract_baseline(self) -> None:
        profile = load_android_live_profile()

        self.assertEqual(profile.schema_version, "1.0.0")
        self.assertEqual(profile.camera.lens_facing, "back")
        self.assertEqual((profile.camera.capture_width, profile.camera.capture_height), (1280, 720))
        self.assertEqual(profile.camera.target_fps, 15)
        self.assertEqual(profile.camera.frame_delivery, "latest_only")
        self.assertEqual(profile.model.name, "yolov11n")
        self.assertEqual(profile.model.runtime, "tflite")
        self.assertEqual((profile.model.input_width, profile.model.input_height), (640, 640))
        self.assertIn("bus", profile.classes)
        self.assertIn("bus_door", profile.classes)
        self.assertIn("obstacle", profile.classes)
        self.assertEqual(profile.output_contract, "ai_vision/pipelines/vision_result.py::VisionResult")
