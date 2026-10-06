"""PC YOLO 기준 모델을 Android용 TensorFlow Lite 파일로 내보내는 도구.

이 도구가 만드는 파일은 COCO 사전학습 ``yolo11n.pt``의 ``bus`` 검증용
기준선이다. 프로젝트 전용 ``bus_door``·장애물 7개 클래스를 지원하는 최종
모델이 아니며, 해당 모델은 별도 데이터 학습 뒤 다시 export해야 한다.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


DEFAULT_SOURCE_MODEL = Path("yolo11n.pt")
DEFAULT_OUTPUT_MODEL = Path("ai_vision/models/yolo11n_coco_bus_baseline_float32.tflite")


def find_tflite_artifact(export_root: Path) -> Path:
    """Ultralytics export 폴더에서 생성된 단일 TFLite 파일을 찾는다."""
    artifacts = sorted(export_root.rglob("*.tflite"))
    if not artifacts:
        raise FileNotFoundError(f"no TFLite artifact found under: {export_root}")
    if len(artifacts) > 1:
        names = ", ".join(str(path) for path in artifacts)
        raise RuntimeError(f"multiple TFLite artifacts found; select one explicitly: {names}")
    return artifacts[0]


def export_android_tflite(
    source_model: Path,
    output_model: Path,
    *,
    image_size: int = 640,
) -> Path:
    """YOLO ``.pt``를 float32 TFLite로 변환하고 B 영역의 산출물 위치에 복사한다.

    TensorFlow가 설치된 Python 3.12/3.13 환경에서 실행해야 한다. float32부터
    검증하는 이유는 int8 양자화 전 정확도·입출력 정합을 먼저 확인하기 위해서다.
    """
    if not source_model.is_file():
        raise FileNotFoundError(f"source model not found: {source_model}")
    if image_size <= 0:
        raise ValueError("image_size must be positive")

    try:
        from ultralytics import YOLO
    except ImportError as exc:
        raise RuntimeError("ultralytics is required for TFLite export") from exc

    model = YOLO(str(source_model))
    # Ultralytics가 SavedModel과 TFLite export directory를 source model 옆에 만든다.
    export_path = Path(model.export(format="tflite", imgsz=image_size, int8=False))
    artifact = export_path if export_path.suffix == ".tflite" else find_tflite_artifact(export_path)
    if not artifact.is_file():
        raise FileNotFoundError(f"Ultralytics reported a missing TFLite artifact: {artifact}")

    output_model.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(artifact, output_model)
    return output_model


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export the bus baseline YOLO model to Android TFLite.")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE_MODEL)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_MODEL)
    parser.add_argument("--image-size", type=int, default=640)
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    artifact = export_android_tflite(args.source, args.output, image_size=args.image_size)
    print(f"Android TFLite baseline written: {artifact}")
    print("Scope: COCO pretrained bus baseline only; bus_door and project-specific classes are not included.")


if __name__ == "__main__":
    main()
