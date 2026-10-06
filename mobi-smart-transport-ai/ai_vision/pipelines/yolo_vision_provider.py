"""Ultralytics-backed VisionProvider for image files and in-memory frames."""
from __future__ import annotations

import math
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

from ai_vision.pipelines.detection_result import (
    BoundingBox,
    Detection,
    DetectionError,
    DetectionResult,
    DetectionStatus,
    ImageSize,
    ModelInfo,
)
from ai_vision.pipelines.taxonomy_mapping import map_coco_class
from ai_vision.pipelines.vision_input import (
    FrameImagePayload,
    MissingImageFileError,
    UnsupportedVisionInputError,
    VisionInferenceRequest,
    VisionInputSource,
)
from ai_vision.pipelines.vision_provider import ProviderConfigurationError


SCHEMA_VERSION = "1.0.0"
ModelFactory = Callable[[str], Any]


class YOLOVisionProvider:
    """Run a local Ultralytics model; never download weights implicitly."""

    def __init__(
        self,
        model_path: str | Path,
        *,
        model_factory: ModelFactory | None = None,
    ) -> None:
        if not isinstance(model_path, (str, Path)) or not str(model_path).strip():
            raise ProviderConfigurationError("A local YOLO model_path is required.")
        self.model_path = Path(model_path).expanduser().resolve()
        if not self.model_path.is_file():
            raise ProviderConfigurationError(
                f"YOLO model weights are unavailable at {self.model_path}; "
                "provide an existing local weight file."
            )

        if model_factory is None:
            try:
                from ultralytics import YOLO
            except ImportError as exc:
                raise ProviderConfigurationError(
                    "YOLO provider requires Ultralytics. Install "
                    "ai_vision/requirements.txt."
                ) from exc
            model_factory = YOLO

        try:
            self._model = model_factory(str(self.model_path))
        except Exception as exc:
            raise ProviderConfigurationError(
                f"Could not load local YOLO model {self.model_path}: {exc}"
            ) from exc

        self.model_info = ModelInfo(
            provider="ultralytics",
            name=self.model_path.stem,
            identifier=str(self.model_path),
        )

    def infer(self, request: VisionInferenceRequest) -> DetectionResult:
        """Infer from one image file and return a schema-compatible result."""
        if not isinstance(request, VisionInferenceRequest):
            raise UnsupportedVisionInputError(
                "YOLOVisionProvider requires a VisionInferenceRequest."
            )
        if request.source is VisionInputSource.IMAGE_FILE:
            if not isinstance(request.payload, Path) or not request.payload.is_file():
                raise MissingImageFileError(f"Image file not found: {request.payload}")
            inference_source: str | object = str(request.payload)
        elif request.source in {VisionInputSource.VIDEO_FILE, VisionInputSource.WEBCAM}:
            if not isinstance(request.payload, FrameImagePayload):
                raise UnsupportedVisionInputError(
                    f"YOLO provider requires an in-memory frame for {request.source.value}."
                )
            inference_source = request.payload.image
        else:
            raise UnsupportedVisionInputError(
                f"YOLO provider does not support source {request.source.value!r}."
            )

        try:
            predictions = self._model.predict(
                source=inference_source,
                verbose=False,
            )
        except Exception as exc:
            return self._error_result(request, "INFERENCE_FAILED", str(exc))

        try:
            detections, image_size = self._convert_predictions(predictions)
        except Exception as exc:
            return self._error_result(
                request,
                "RESULT_CONVERSION_FAILED",
                str(exc),
            )

        return DetectionResult(
            schema_version=SCHEMA_VERSION,
            source=request.source.value,
            status=DetectionStatus.OK,
            detections=tuple(detections),
            frame_id=request.frame_id,
            captured_at=request.captured_at,
            image_size=image_size,
            model_info=self.model_info,
        )

    def _convert_predictions(
        self,
        predictions: Sequence[Any],
    ) -> tuple[list[Detection], ImageSize]:
        if not predictions:
            raise ValueError("Ultralytics returned no image result.")
        result = predictions[0]
        height, width = result.orig_shape
        if width <= 0 or height <= 0:
            raise ValueError("YOLO result has an invalid original image size.")

        boxes = result.boxes
        if boxes is None:
            return [], ImageSize(width=int(width), height=int(height))

        xyxy_rows = _as_list(boxes.xyxy)
        class_ids = [_scalar(item) for item in _as_list(boxes.cls)]
        confidences = [_scalar(item) for item in _as_list(boxes.conf)]
        if not (len(xyxy_rows) == len(class_ids) == len(confidences)):
            raise ValueError("YOLO boxes, classes, and confidences have different lengths.")

        detections: list[Detection] = []
        for xyxy, raw_class_id, confidence in zip(
            xyxy_rows,
            class_ids,
            confidences,
            strict=True,
        ):
            class_name = _resolve_class_name(result.names, int(raw_class_id))
            mapped_class = map_coco_class(class_name)
            if mapped_class is None:
                continue
            class_id, project_class_name = mapped_class
            confidence = float(confidence)
            if not math.isfinite(confidence) or not 0 <= confidence <= 1:
                raise ValueError(f"YOLO returned invalid confidence {confidence!r}.")

            x1, y1, x2, y2 = (float(value) for value in xyxy)
            coordinates = (x1, y1, x2, y2)
            if not all(math.isfinite(value) for value in coordinates):
                raise ValueError("YOLO returned non-finite bbox coordinates.")
            left = min(max(x1, 0.0), float(width))
            top = min(max(y1, 0.0), float(height))
            right = min(max(x2, 0.0), float(width))
            bottom = min(max(y2, 0.0), float(height))
            if right <= left or bottom <= top:
                raise ValueError("YOLO returned an empty or inverted bbox.")

            detections.append(
                Detection(
                    class_id=class_id,
                    class_name=project_class_name,
                    confidence=confidence,
                    bbox=BoundingBox(
                        x=left / width,
                        y=top / height,
                        w=(right - left) / width,
                        h=(bottom - top) / height,
                    ),
                )
            )
        return detections, ImageSize(width=int(width), height=int(height))

    def _error_result(
        self,
        request: VisionInferenceRequest,
        code: str,
        message: str,
    ) -> DetectionResult:
        return DetectionResult(
            schema_version=SCHEMA_VERSION,
            source=request.source.value,
            status=DetectionStatus.ERROR,
            detections=(),
            frame_id=request.frame_id,
            captured_at=request.captured_at,
            model_info=self.model_info,
            error=DetectionError(code=code, message=message or code),
        )


def _as_list(value: Any) -> list[Any]:
    if hasattr(value, "detach"):
        value = value.detach().cpu()
    if hasattr(value, "tolist"):
        value = value.tolist()
    return list(value)


def _scalar(value: Any) -> Any:
    while isinstance(value, (list, tuple)) and len(value) == 1:
        value = value[0]
    if hasattr(value, "item"):
        value = value.item()
    return value


def _resolve_class_name(names: Any, class_id: int) -> str:
    if isinstance(names, Mapping):
        name = names.get(class_id, names.get(str(class_id)))
    else:
        name = names[class_id] if isinstance(names, Sequence) else None
    if not isinstance(name, str) or not name.strip():
        raise ValueError(f"YOLO result does not define class ID {class_id}.")
    return name
