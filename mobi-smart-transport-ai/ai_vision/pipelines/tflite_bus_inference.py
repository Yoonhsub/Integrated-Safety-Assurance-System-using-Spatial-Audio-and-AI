"""Android TFLite YOLO11 출력에서 ``bus``를 프로젝트 VisionResult로 변환한다.

이 파일은 Android 앱 구현 전에 동일한 입·출력 흐름을 PC에서 검증하기 위한
참조 어댑터다. Android 구현도 아래 순서를 그대로 따르면 된다.

``camera frame -> letterbox/RGB/float32 -> [1,84,8400] -> bus/NMS -> VisionResult``

COCO 사전학습 기준선만 다루므로 ``bus``(COCO class 5)만 계약으로 내보낸다.
``bus_door``와 프로젝트 전용 클래스는 별도 학습 모델이 준비된 뒤 추가한다.
"""

from __future__ import annotations

import argparse
import json
import math
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

from guidance_handoff import build_vision_guidance_handoff
from spatial_guidance import interpret_bus_guidance
from vision_result import ImageSize, RawDetection, VisionResult, VisionResultValidationError, build_vision_result


COCO_BUS_CLASS_INDEX = 5
DEFAULT_INPUT_WIDTH = 640
DEFAULT_INPUT_HEIGHT = 640
DEFAULT_BUS_CONFIDENCE_THRESHOLD = 0.50
DEFAULT_NMS_IOU_THRESHOLD = 0.45
DEFAULT_MODEL_NAME = "yolov11n"
DEFAULT_MODEL_VERSION = "coco-tflite-float32-baseline"
DEFAULT_MODEL_PATH = Path("ai_vision/models/yolo11n_coco_bus_baseline_float32.tflite")
# 이 SavedModel 기반 export는 box 좌표도 640 pixel 값이 아니라 0~1 비율로 낸다.
TFLITE_OUTPUT_COORDINATES_NORMALIZED = True


@dataclass(frozen=True)
class LetterboxTransform:
    """원본 프레임과 모델 입력 사이의 크기·여백 변환값."""

    source_size: ImageSize
    input_width: int
    input_height: int
    scale_x: float
    scale_y: float
    pad_x: float
    pad_y: float

    def __post_init__(self) -> None:
        if self.input_width <= 0 or self.input_height <= 0:
            raise VisionResultValidationError("TFLite input dimensions must be positive")
        if self.scale_x <= 0 or self.scale_y <= 0:
            raise VisionResultValidationError("letterbox scale must be positive")


def make_letterbox_transform(
    source_size: ImageSize,
    *,
    input_width: int = DEFAULT_INPUT_WIDTH,
    input_height: int = DEFAULT_INPUT_HEIGHT,
) -> LetterboxTransform:
    """비율을 유지해 원본 프레임을 모델 입력 크기에 맞추는 변환값을 만든다."""
    if input_width <= 0 or input_height <= 0:
        raise VisionResultValidationError("TFLite input dimensions must be positive")

    scale = min(input_width / source_size.width, input_height / source_size.height)
    resized_width = max(1, round(source_size.width * scale))
    resized_height = max(1, round(source_size.height * scale))
    return LetterboxTransform(
        source_size=source_size,
        input_width=input_width,
        input_height=input_height,
        scale_x=resized_width / source_size.width,
        scale_y=resized_height / source_size.height,
        pad_x=(input_width - resized_width) / 2,
        pad_y=(input_height - resized_height) / 2,
    )


def _iou(first: RawDetection, second: RawDetection) -> float:
    left = max(first.x1, second.x1)
    top = max(first.y1, second.y1)
    right = min(first.x2, second.x2)
    bottom = min(first.y2, second.y2)
    intersection = max(0.0, right - left) * max(0.0, bottom - top)
    first_area = max(0.0, first.x2 - first.x1) * max(0.0, first.y2 - first.y1)
    second_area = max(0.0, second.x2 - second.x1) * max(0.0, second.y2 - second.y1)
    union = first_area + second_area - intersection
    return intersection / union if union > 0 else 0.0


def non_maximum_suppression(
    detections: Sequence[RawDetection], *, iou_threshold: float = DEFAULT_NMS_IOU_THRESHOLD
) -> list[RawDetection]:
    """같은 버스에 대한 겹치는 후보를 가장 높은 score 하나로 정리한다."""
    if not 0.0 < iou_threshold <= 1.0:
        raise VisionResultValidationError("NMS IoU threshold must be in (0, 1]")
    kept: list[RawDetection] = []
    for candidate in sorted(detections, key=lambda item: item.score, reverse=True):
        if all(_iou(candidate, selected) < iou_threshold for selected in kept):
            kept.append(candidate)
    return kept


def _model_box_to_source(
    *, center_x: float, center_y: float, width: float, height: float, transform: LetterboxTransform
) -> tuple[float, float, float, float] | None:
    """모델의 정규화 ``xywh``를 원본 이미지의 경계 안 ``xyxy``로 되돌린다."""
    values = (center_x, center_y, width, height)
    if not all(math.isfinite(value) for value in values) or width <= 0 or height <= 0:
        return None
    if TFLITE_OUTPUT_COORDINATES_NORMALIZED:
        center_x *= transform.input_width
        center_y *= transform.input_height
        width *= transform.input_width
        height *= transform.input_height
    left = (center_x - width / 2 - transform.pad_x) / transform.scale_x
    top = (center_y - height / 2 - transform.pad_y) / transform.scale_y
    right = (center_x + width / 2 - transform.pad_x) / transform.scale_x
    bottom = (center_y + height / 2 - transform.pad_y) / transform.scale_y
    left = min(max(left, 0.0), float(transform.source_size.width))
    top = min(max(top, 0.0), float(transform.source_size.height))
    right = min(max(right, 0.0), float(transform.source_size.width))
    bottom = min(max(bottom, 0.0), float(transform.source_size.height))
    return (left, top, right, bottom) if right > left and bottom > top else None


def decode_bus_detections(
    output: Sequence[Sequence[Sequence[float]]],
    *,
    transform: LetterboxTransform,
    confidence_threshold: float = DEFAULT_BUS_CONFIDENCE_THRESHOLD,
    nms_iou_threshold: float = DEFAULT_NMS_IOU_THRESHOLD,
) -> list[RawDetection]:
    """YOLO11 TFLite ``[1, 84, 8400]`` 출력을 픽셀 좌표 버스 후보로 해석한다.

    YOLO11 detect export의 채널 0~3은 0~1 기준의 ``cx, cy, w, h``이며, 채널
    ``4 + 5``는 COCO bus 점수다. 이 기준선 모델에는 별도 objectness 채널이 없다.
    """
    if not 0.0 <= confidence_threshold <= 1.0:
        raise VisionResultValidationError("confidence threshold must be in [0, 1]")
    if len(output) != 1 or len(output[0]) != 84:
        raise VisionResultValidationError("expected TFLite output shape [1, 84, candidate_count]")

    channels = output[0]
    candidate_count = len(channels[0])
    if candidate_count <= 0 or any(len(channel) != candidate_count for channel in channels):
        raise VisionResultValidationError("TFLite output channels must have equal non-zero length")

    raw: list[RawDetection] = []
    bus_score_channel = 4 + COCO_BUS_CLASS_INDEX
    for index in range(candidate_count):
        score = float(channels[bus_score_channel][index])
        if not math.isfinite(score) or score < confidence_threshold:
            continue
        source_box = _model_box_to_source(
            center_x=float(channels[0][index]),
            center_y=float(channels[1][index]),
            width=float(channels[2][index]),
            height=float(channels[3][index]),
            transform=transform,
        )
        if source_box is None:
            continue
        raw.append(RawDetection(class_id="bus", score=min(score, 1.0), x1=source_box[0], y1=source_box[1], x2=source_box[2], y2=source_box[3]))
    return non_maximum_suppression(raw, iou_threshold=nms_iou_threshold)


def vision_result_from_tflite_output(
    output: Sequence[Sequence[Sequence[float]]],
    *,
    source_size: ImageSize,
    input_width: int = DEFAULT_INPUT_WIDTH,
    input_height: int = DEFAULT_INPUT_HEIGHT,
    confidence_threshold: float = DEFAULT_BUS_CONFIDENCE_THRESHOLD,
    nms_iou_threshold: float = DEFAULT_NMS_IOU_THRESHOLD,
) -> VisionResult:
    """TFLite 출력 하나를 기존 프로젝트 ``VisionResult`` 계약으로 바꾼다."""
    transform = make_letterbox_transform(source_size, input_width=input_width, input_height=input_height)
    return build_vision_result(
        frame_id=str(uuid.uuid4()),
        captured_at=datetime.now(timezone.utc),
        image_size=source_size,
        raw_detections=decode_bus_detections(
            output,
            transform=transform,
            confidence_threshold=confidence_threshold,
            nms_iou_threshold=nms_iou_threshold,
        ),
        model_name=DEFAULT_MODEL_NAME,
        model_version=DEFAULT_MODEL_VERSION,
    )


def _preprocess_bgr_image(image_bgr: Any, transform: LetterboxTransform) -> Any:
    """OpenCV BGR 프레임을 모델 입력 ``[1,H,W,3] float32 RGB``로 만든다."""
    try:
        import cv2
        import numpy as np
    except ImportError as exc:
        raise RuntimeError("TFLite image preprocessing requires opencv-python and numpy") from exc

    resized_width = round(transform.source_size.width * transform.scale_x)
    resized_height = round(transform.source_size.height * transform.scale_y)
    resized = cv2.resize(image_bgr, (resized_width, resized_height), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((transform.input_height, transform.input_width, 3), 114, dtype=np.uint8)
    left, top = round(transform.pad_x), round(transform.pad_y)
    canvas[top : top + resized_height, left : left + resized_width] = resized
    rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)
    return np.expand_dims(rgb.astype(np.float32) / 255.0, axis=0)


def run_tflite_image_inference(
    source: Path,
    *,
    model_path: Path = DEFAULT_MODEL_PATH,
    confidence_threshold: float = DEFAULT_BUS_CONFIDENCE_THRESHOLD,
    nms_iou_threshold: float = DEFAULT_NMS_IOU_THRESHOLD,
) -> VisionResult:
    """실제 이미지 한 장으로 TFLite 모델부터 안내 후보까지 검증한다."""
    if not source.is_file():
        raise FileNotFoundError(f"source image not found: {source}")
    if not model_path.is_file():
        raise FileNotFoundError(f"TFLite model not found: {model_path}")
    try:
        import cv2
        import tensorflow as tf
    except ImportError as exc:
        raise RuntimeError("TFLite runtime dependencies are unavailable. Run this in the Docker export image.") from exc

    image_bgr = cv2.imread(str(source))
    if image_bgr is None:
        raise VisionResultValidationError(f"unable to decode source image: {source}")
    height, width = image_bgr.shape[:2]
    source_size = ImageSize(width=width, height=height)
    interpreter = tf.lite.Interpreter(model_path=str(model_path))
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    input_shape = tuple(int(value) for value in input_detail["shape"])
    if len(input_shape) != 4 or input_shape[0] != 1 or input_shape[3] != 3:
        raise VisionResultValidationError(f"unexpected TFLite input shape: {input_shape}")
    transform = make_letterbox_transform(source_size, input_width=input_shape[2], input_height=input_shape[1])
    interpreter.set_tensor(input_detail["index"], _preprocess_bgr_image(image_bgr, transform))
    interpreter.invoke()
    output_detail = interpreter.get_output_details()[0]
    output = interpreter.get_tensor(output_detail["index"]).tolist()
    return vision_result_from_tflite_output(
        output,
        source_size=source_size,
        input_width=input_shape[2],
        input_height=input_shape[1],
        confidence_threshold=confidence_threshold,
        nms_iou_threshold=nms_iou_threshold,
    )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Android TFLite bus baseline on one image.")
    parser.add_argument("--source", required=True, type=Path, help="Input image path")
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL_PATH, help="TFLite model path")
    parser.add_argument("--output", required=True, type=Path, help="JSON result path")
    parser.add_argument("--confidence", type=float, default=DEFAULT_BUS_CONFIDENCE_THRESHOLD)
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    result = run_tflite_image_inference(args.source, model_path=args.model, confidence_threshold=args.confidence)
    handoff = build_vision_guidance_handoff(result)
    guidance = interpret_bus_guidance(result)
    payload = {
        "visionResult": result.as_contract_payload(),
        "spatialGuidance": guidance.as_dict() if guidance is not None else None,
        "visionGuidanceHandoff": handoff.as_dict(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"TFLite VisionResult written: {args.output}")
    print(f"Supported detections: {len(result.detections)}")
    for detection in result.detections:
        print(f"- {detection.class_id}: score={detection.score:.3f}, bbox={detection.bbox.as_dict()}")


if __name__ == "__main__":
    main()
