"""Android 기기 없이 이미지·녹화 영상 프레임으로 AI Vision을 검증하는 실행기.

이 모듈은 실제 YOLO 모델의 원본 출력(``xyxy``, class index, confidence)을
프로젝트 공통 ``VisionResult``로 변환한다. Android 카메라 연결 전, 모델이 낸
결과 자체와 프로젝트 계약의 연결을 PC에서 먼저 검증하기 위한 도구다.

실행 예시::

    .\\.vision-env\\Scripts\\python.exe ai_vision/pipelines/offline_yolo_inference.py \\
        --source ai_vision/pipelines/fixtures/external/bus.jpg \\
        --output ai_vision/pipelines/fixtures/external/bus.vision-result.json
"""

from __future__ import annotations

import argparse
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

from guidance_handoff import build_vision_guidance_handoff
from spatial_guidance import interpret_bus_guidance
from vision_result import ImageSize, RawDetection, VisionResult, VisionResultValidationError, build_vision_result


DEFAULT_MODEL = "yolo11n.pt"
DEFAULT_MODEL_NAME = "yolov11n"
DEFAULT_MODEL_VERSION = "pretrained-coco-baseline"


def raw_detections_from_model_outputs(
    *,
    class_indices: Sequence[float],
    scores: Sequence[float],
    boxes_xyxy: Sequence[Sequence[float]],
    names: Mapping[int, str] | Sequence[str],
) -> list[RawDetection]:
    """YOLO의 배열 결과를 SDK에 독립적인 ``RawDetection`` 목록으로 바꾼다."""
    if not (len(class_indices) == len(scores) == len(boxes_xyxy)):
        raise VisionResultValidationError("YOLO class, score, and bbox arrays must have equal length")

    detections: list[RawDetection] = []
    for class_index, score, box in zip(class_indices, scores, boxes_xyxy):
        index = int(class_index)
        try:
            class_id = names[index]
        except (IndexError, KeyError, TypeError) as exc:
            raise VisionResultValidationError(f"YOLO class index is unknown: {index}") from exc
        if len(box) != 4:
            raise VisionResultValidationError("YOLO bbox must contain four xyxy values")
        detections.append(
            RawDetection(
                class_id=str(class_id),
                score=float(score),
                x1=float(box[0]),
                y1=float(box[1]),
                x2=float(box[2]),
                y2=float(box[3]),
            )
        )
    return detections


def run_image_inference(
    source: Path,
    *,
    model_path: str = DEFAULT_MODEL,
    model_name: str = DEFAULT_MODEL_NAME,
    model_version: str = DEFAULT_MODEL_VERSION,
) -> VisionResult:
    """이미지 한 장을 실제 YOLO 모델로 추론해 ``VisionResult``로 반환한다.

    ``ultralytics``와 ``opencv-python``은 프로젝트의 ``.vision-env``에만 설치한다.
    따라서 일반 단위 테스트나 앱 코드는 이 개발용 의존성을 요구하지 않는다.
    """
    if not source.is_file():
        raise FileNotFoundError(f"source image not found: {source}")

    try:
        import cv2
        from ultralytics import YOLO
    except ImportError as exc:
        raise RuntimeError(
            "offline YOLO dependencies are unavailable. Use .vision-env before running inference."
        ) from exc

    image = cv2.imread(str(source))
    if image is None:
        raise VisionResultValidationError(f"unable to decode source image: {source}")

    model = YOLO(model_path)
    result = model(image, verbose=False)[0]
    return _vision_result_from_yolo_result(
        result=result,
        image=image,
        model_name=model_name,
        model_version=model_version,
    )


def frame_indices_to_process(
    *,
    total_frames: int,
    frame_stride: int,
    max_samples: int | None,
) -> list[int]:
    """영상 전체에서 처리할 프레임 번호를 계산한다.

    매 프레임을 모두 처리하면 안내 결과가 늦게 쌓일 수 있어, 오프라인 검증에서도
    Android의 ``latest_only`` 정책과 같은 의도로 일정 간격을 둔다.
    """
    if total_frames < 0:
        raise VisionResultValidationError("total_frames must not be negative")
    if frame_stride <= 0:
        raise VisionResultValidationError("frame_stride must be positive")
    if max_samples is not None and max_samples <= 0:
        raise VisionResultValidationError("max_samples must be positive when set")
    indices = list(range(0, total_frames, frame_stride))
    return indices if max_samples is None else indices[:max_samples]


def _vision_result_from_yolo_result(
    *,
    result: Any,
    image: Any,
    model_name: str,
    model_version: str,
) -> VisionResult:
    """한 YOLO result 객체와 원본 frame을 ``VisionResult``로 변환한다."""
    height, width = image.shape[:2]
    boxes = result.boxes
    raw_detections = raw_detections_from_model_outputs(
        class_indices=boxes.cls.cpu().tolist(),
        scores=boxes.conf.cpu().tolist(),
        boxes_xyxy=boxes.xyxy.cpu().tolist(),
        names=result.names,
    )
    return build_vision_result(
        frame_id=str(uuid.uuid4()),
        captured_at=datetime.now(timezone.utc),
        image_size=ImageSize(width=width, height=height),
        raw_detections=raw_detections,
        model_name=model_name,
        model_version=model_version,
    )


def run_video_inference(
    source: Path,
    *,
    model_path: str = DEFAULT_MODEL,
    frame_stride: int = 15,
    max_samples: int | None = 20,
    model_name: str = DEFAULT_MODEL_NAME,
    model_version: str = DEFAULT_MODEL_VERSION,
) -> dict[str, object]:
    """영상의 일정 간격 프레임을 실제 YOLO로 추론해 시간별 결과를 반환한다."""
    if not source.is_file():
        raise FileNotFoundError(f"source video not found: {source}")
    try:
        import cv2
        from ultralytics import YOLO
    except ImportError as exc:
        raise RuntimeError(
            "offline YOLO dependencies are unavailable. Use .vision-env before running inference."
        ) from exc

    capture = cv2.VideoCapture(str(source))
    if not capture.isOpened():
        raise VisionResultValidationError(f"unable to open source video: {source}")
    try:
        total_frames = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = float(capture.get(cv2.CAP_PROP_FPS))
        if fps <= 0:
            raise VisionResultValidationError("source video must report a positive FPS")
        indices = frame_indices_to_process(
            total_frames=total_frames,
            frame_stride=frame_stride,
            max_samples=max_samples,
        )
        model = YOLO(model_path)
        samples: list[dict[str, object]] = []
        previous_vision_result: VisionResult | None = None
        for frame_index in indices:
            capture.set(cv2.CAP_PROP_POS_FRAMES, frame_index)
            ok, frame = capture.read()
            if not ok or frame is None:
                raise VisionResultValidationError(f"unable to read video frame {frame_index}")
            result = model(frame, verbose=False)[0]
            vision_result = _vision_result_from_yolo_result(
                result=result,
                image=frame,
                model_name=model_name,
                model_version=model_version,
            )
            guidance = interpret_bus_guidance(vision_result, previous_vision_result)
            handoff = build_vision_guidance_handoff(vision_result, previous_vision_result)
            samples.append(
                {
                    "frameIndex": frame_index,
                    "offsetMillis": round(frame_index / fps * 1000),
                    "visionResult": vision_result.as_contract_payload(),
                    # 실제 미터 거리가 아니라 화면 bbox 기반의 임시 안내 후보이다.
                    # Context/SAL 계층은 이 값을 위험도 확정값으로 취급하면 안 된다.
                    "spatialGuidance": guidance.as_dict() if guidance is not None else None,
                    # Context/음성 담당자에게 제시할 합의 전 후보 payload.
                    "visionGuidanceHandoff": handoff.as_dict(),
                }
            )
            previous_vision_result = vision_result
        return {
            "source": str(source),
            "fps": fps,
            "totalFrames": total_frames,
            "frameStride": frame_stride,
            "samples": samples,
        }
    finally:
        capture.release()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run offline YOLO inference and emit a VisionResult JSON file.")
    parser.add_argument("--source", required=True, type=Path, help="Input image or video path")
    parser.add_argument("--output", required=True, type=Path, help="VisionResult JSON output path")
    parser.add_argument(
        "--guidance-output",
        type=Path,
        help="Optional image-mode guidance-candidate JSON output path",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL, help="YOLO model path or model filename")
    parser.add_argument("--model-name", default=DEFAULT_MODEL_NAME, help="Model name recorded in the result JSON")
    parser.add_argument("--model-version", default=DEFAULT_MODEL_VERSION, help="Model version recorded in the result JSON")
    parser.add_argument("--video", action="store_true", help="Treat source as video and sample its frames")
    parser.add_argument("--frame-stride", type=int, default=15, help="Process every Nth video frame")
    parser.add_argument("--max-samples", type=int, default=20, help="Maximum video frames to process")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    if args.video:
        payload = run_video_inference(
            args.source,
            model_path=args.model,
            frame_stride=args.frame_stride,
            max_samples=args.max_samples,
            model_name=args.model_name,
            model_version=args.model_version,
        )
        summary = f"Video samples written: {len(payload['samples'])}"
    else:
        result = run_image_inference(
            args.source,
            model_path=args.model,
            model_name=args.model_name,
            model_version=args.model_version,
        )
        payload = result.as_contract_payload()
        summary = f"Supported detections: {len(result.detections)}"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    if args.guidance_output is not None and not args.video:
        guidance = build_vision_guidance_handoff(result)
        args.guidance_output.parent.mkdir(parents=True, exist_ok=True)
        args.guidance_output.write_text(
            json.dumps(guidance.as_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"Guidance candidates written: {args.guidance_output}")
    print(f"VisionResult written: {args.output}")
    print(summary)
    if not args.video:
        for detection in result.detections:
            print(f"- {detection.class_id}: score={detection.score:.3f}, bbox={detection.bbox.as_dict()}")


if __name__ == "__main__":
    main()
