"""개발 일정 1주차 Android AI Vision 기준 프로필 로더.

카메라 구현과 모델 SDK는 플랫폼 계층의 책임이지만, 어떤 입력과 모델 출력을
``VisionResult`` 계약으로 연결할지는 AI Vision 영역에서 고정한다.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from vision_result import VisionResultValidationError, load_taxonomy_thresholds


DEFAULT_PROFILE_PATH = Path(__file__).resolve().parent / "android_live_profile.json"


@dataclass(frozen=True)
class AndroidCameraProfile:
    lens_facing: str
    capture_width: int
    capture_height: int
    target_fps: int
    frame_delivery: str


@dataclass(frozen=True)
class AndroidModelProfile:
    name: str
    runtime: str
    input_width: int
    input_height: int
    asset_path: str
    status: str


@dataclass(frozen=True)
class AndroidLiveProfile:
    schema_version: str
    camera: AndroidCameraProfile
    model: AndroidModelProfile
    classes: tuple[str, ...]
    output_contract: str


def _require_positive_int(value: object, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise VisionResultValidationError(f"{field} must be a positive integer")
    return value


def load_android_live_profile(
    path: Path = DEFAULT_PROFILE_PATH,
    *,
    taxonomy_thresholds: dict[str, float] | None = None,
) -> AndroidLiveProfile:
    """Android 실기기 기준 설정을 읽고 taxonomy 및 입력 계약과 정합성을 검증한다."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        camera_payload = payload["camera"]
        model_payload = payload["model"]
        classes = payload["classes"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        raise VisionResultValidationError(f"unable to load Android live profile: {path}") from exc

    if payload.get("platform") != "android":
        raise VisionResultValidationError("live profile platform must be android")
    if camera_payload.get("lens_facing") != "back":
        raise VisionResultValidationError("live profile must use the rear camera")
    if camera_payload.get("frame_delivery") != "latest_only":
        raise VisionResultValidationError("live profile must drop stale camera frames")
    if model_payload.get("runtime") != "tflite":
        raise VisionResultValidationError("Android baseline runtime must be tflite")
    if not isinstance(classes, list) or not classes or len(classes) != len(set(classes)):
        raise VisionResultValidationError("classes must be a non-empty list without duplicates")

    known_classes = taxonomy_thresholds or load_taxonomy_thresholds()
    unknown_classes = set(classes) - set(known_classes)
    if unknown_classes:
        raise VisionResultValidationError(
            f"profile includes classes absent from taxonomy: {sorted(unknown_classes)}"
        )

    camera = AndroidCameraProfile(
        lens_facing=camera_payload["lens_facing"],
        capture_width=_require_positive_int(camera_payload["capture_width"], "capture_width"),
        capture_height=_require_positive_int(camera_payload["capture_height"], "capture_height"),
        target_fps=_require_positive_int(camera_payload["target_fps"], "target_fps"),
        frame_delivery=camera_payload["frame_delivery"],
    )
    model = AndroidModelProfile(
        name=str(model_payload["name"]),
        runtime=model_payload["runtime"],
        input_width=_require_positive_int(model_payload["input_width"], "input_width"),
        input_height=_require_positive_int(model_payload["input_height"], "input_height"),
        asset_path=str(model_payload["asset_path"]),
        status=str(model_payload["status"]),
    )
    if not model.name or not model.asset_path:
        raise VisionResultValidationError("model name and asset path are required")

    return AndroidLiveProfile(
        schema_version=str(payload["schema_version"]),
        camera=camera,
        model=model,
        classes=tuple(classes),
        output_contract=str(payload["output_contract"]),
    )
