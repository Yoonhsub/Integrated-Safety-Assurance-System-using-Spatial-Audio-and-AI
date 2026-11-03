"""Decoder adapted from feature/add-tflite-baseline at 0d2b911.

Only RGB/letterbox, class-specific decoding and NMS are reused. No guidance,
wall-clock timestamp generation or taxonomy wording is imported.
"""
from __future__ import annotations
import math
from dataclasses import dataclass
from typing import Any, Sequence
from ai_vision.pipelines.detection_result import ImageSize

class VisionResultValidationError(ValueError):
    pass

@dataclass(frozen=True)
class RawDetection:
    class_id: str
    score: float
    x1: float
    y1: float
    x2: float
    y2: float

COCO_BUS_CLASS_INDEX = 5
BUS_DOOR_BUS_CLASS_INDEX = 0
BUS_DOOR_CLASS_INDEX = 1
DEFAULT_INPUT_WIDTH = 640
DEFAULT_INPUT_HEIGHT = 640
DEFAULT_BUS_CONFIDENCE_THRESHOLD = 0.50
DEFAULT_NMS_IOU_THRESHOLD = 0.45
DEFAULT_MODEL_NAME = "yolov11n"
DEFAULT_MODEL_VERSION = "coco-tflite-float32-baseline"

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
        pad_x=round((input_width - resized_width) / 2),
        pad_y=round((input_height - resized_height) / 2),
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
        if not math.isfinite(score) or not 0 <= score <= 1:
            raise VisionResultValidationError("invalid model confidence")
        if score < confidence_threshold:
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
        raw.append(RawDetection(class_id="bus", score=score, x1=source_box[0], y1=source_box[1], x2=source_box[2], y2=source_box[3]))
    return non_maximum_suppression(raw, iou_threshold=nms_iou_threshold)


def decode_bus_door_detections(
    output: Sequence[Sequence[Sequence[float]]],
    *,
    transform: LetterboxTransform,
    confidence_threshold: float = DEFAULT_BUS_CONFIDENCE_THRESHOLD,
    nms_iou_threshold: float = DEFAULT_NMS_IOU_THRESHOLD,
) -> list[RawDetection]:
    """버스 문 모델의 ``[1, 6, 8400]`` 출력을 두 프로젝트 클래스로 해석한다.

    채널 0~3은 정규화된 ``cx, cy, w, h``이며 채널 4, 5는 각각 ``bus``,
    ``bus_door`` 점수다. NMS는 클래스별로 적용해야 문 박스가 버스 차체 박스에
    의해 제거되지 않는다.
    """
    if not 0.0 <= confidence_threshold <= 1.0:
        raise VisionResultValidationError("confidence threshold must be in [0, 1]")
    if len(output) != 1 or len(output[0]) != 6:
        raise VisionResultValidationError("expected bus-door TFLite output shape [1, 6, candidate_count]")

    channels = output[0]
    candidate_count = len(channels[0])
    if candidate_count <= 0 or any(len(channel) != candidate_count for channel in channels):
        raise VisionResultValidationError("TFLite output channels must have equal non-zero length")

    class_channels = ((BUS_DOOR_BUS_CLASS_INDEX, "bus"), (BUS_DOOR_CLASS_INDEX, "bus_door"))
    by_class: dict[str, list[RawDetection]] = {class_id: [] for _, class_id in class_channels}
    for index in range(candidate_count):
        source_box = _model_box_to_source(
            center_x=float(channels[0][index]),
            center_y=float(channels[1][index]),
            width=float(channels[2][index]),
            height=float(channels[3][index]),
            transform=transform,
        )
        if source_box is None:
            continue
        for class_index, class_id in class_channels:
            score = float(channels[4 + class_index][index])
            if not math.isfinite(score) or not 0 <= score <= 1:
                raise VisionResultValidationError("invalid model confidence")
            if score >= confidence_threshold:
                by_class[class_id].append(
                    RawDetection(class_id=class_id, score=score, x1=source_box[0], y1=source_box[1], x2=source_box[2], y2=source_box[3])
                )
    return [
        detection
        for class_id in ("bus", "bus_door")
        for detection in non_maximum_suppression(by_class[class_id], iou_threshold=nms_iou_threshold)
    ]


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
