"""Strict TFLite profiles and adapter for the existing DetectionResult contract."""
from __future__ import annotations
import hashlib
import math
import threading
import time
from pathlib import Path

from ai_vision.pipelines.detection_result import (BoundingBox, Detection, DetectionError,
    DetectionResult, DetectionStatus, ImageSize, ModelInfo)
from ai_vision.pipelines.vision_input import VisionInferenceRequest, VisionInputSource
from ai_vision.pipelines.vision_provider import ProviderConfigurationError
from ai_vision.pipelines.tflite_decoding import (make_letterbox_transform,
    _preprocess_bgr_image, decode_bus_detections, decode_bus_door_detections)

# Explicit artifact identity prevents a two-class obstacle model being decoded as bus/door.
PROFILES = {
    'coco-bus': {'sha256': '829a6f01553dba4786b4675fb86ce2572da560da1ce03364808cd014765eb60f',
                 'channels': 84, 'classes': ('bus',), 'name': 'yolo11n_coco_bus_baseline_float32'},
    'bus-door': {'sha256': '7178a76b3abaa83bfac0ad9c5b1ea40627560d6aa0e05587b335950a1bffaa85',
                 'channels': 6, 'classes': ('bus', 'bus_door'), 'name': 'yolo11n_bus_door_v1_float32'},
}
NAMES = {'bus': '버스', 'bus_door': '버스 문'}


def adapt_vision_result(payload, request: VisionInferenceRequest, model: ModelInfo, allowed_classes):
    """Adapt the team's local payload; require original request identity, never retime."""
    if hasattr(payload, 'as_contract_payload'):
        payload = payload.as_contract_payload()
    if payload['frameId'] != request.frame_id or payload['capturedAt'] != request.captured_at:
        raise ValueError('VisionResult identity/time differs from input frame')
    size = payload['imageSize']
    if any(type(size[k]) is not int or size[k] <= 0 for k in ('width', 'height')):
        raise ValueError('Invalid image resolution')
    detections = []
    for item in payload['detections']:
        cls = item['classId']
        if cls not in allowed_classes or cls not in NAMES:
            raise ValueError('Unsupported model class')
        score = item['score']
        coords = [item['bbox'][k] for k in ('x','y','w','h')]
        if any(isinstance(v, bool) or not isinstance(v,(int,float)) or not math.isfinite(v) for v in [score,*coords]):
            raise ValueError('Non-finite/non-numeric detection')
        x,y,w,h = coords
        if not (0 <= score <= 1 and 0 <= x < 1 and 0 <= y < 1 and w > 0 and h > 0
                and x+w <= 1 and y+h <= 1):
            raise ValueError('Detection out of range')
        detections.append(Detection(cls,NAMES[cls],score,BoundingBox(x,y,w,h)))
    return DetectionResult('1.0.0', request.source.value, DetectionStatus.OK, tuple(detections),
        request.frame_id, request.captured_at, ImageSize(**size), model)


class TFLiteVisionProvider:
    def __init__(self, model_path, *, profile):
        if profile not in PROFILES:
            raise ProviderConfigurationError('Select an explicit supported TFLite profile')
        self.profile = PROFILES[profile]
        self.profile_name = profile
        path = Path(model_path)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != self.profile['sha256']:
            raise ProviderConfigurationError('TFLite artifact missing or SHA256/profile mismatch')
        try:
            import numpy as np
            import tensorflow as tf
            self._interpreter = tf.lite.Interpreter(model_path=str(path), num_threads=2)
            self._interpreter.allocate_tensors()
            inputs, outputs = self._interpreter.get_input_details(), self._interpreter.get_output_details()
            if len(inputs) != 1 or len(outputs) != 1:
                raise ValueError('Expected one input and one output')
            self._input, self._output = inputs[0], outputs[0]
            if (tuple(self._input['shape']) != (1,640,640,3) or self._input['dtype'] != np.float32
                or tuple(self._output['shape']) != (1,self.profile['channels'],8400)
                or self._output['dtype'] != np.float32):
                raise ValueError('Unexpected tensor shape/dtype')
        except Exception as exc:
            raise ProviderConfigurationError('Could not initialize verified TFLite runtime/tensors') from exc
        self.model_info = ModelInfo('tflite',self.profile['name'],'0d2b911', 'sha256:'+self.profile['sha256'])
        self.last_timings = {}
        self._lock = threading.RLock()

    def warm_up(self):
        import numpy as np
        started = time.perf_counter()
        try:
            with self._lock:
                self._interpreter.set_tensor(self._input['index'],np.zeros((1,640,640,3),np.float32))
                self._interpreter.invoke()
        except Exception as exc:
            raise ProviderConfigurationError('TFLite warm-up failed') from exc
        return time.perf_counter()-started

    def infer(self, request):
        if not isinstance(request, VisionInferenceRequest):
            raise TypeError('TFLite requires VisionInferenceRequest')
        with self._lock:
            self.last_timings = {}
            try:
                import cv2
                import numpy as np
                image = cv2.imread(str(request.payload)) if request.source is VisionInputSource.IMAGE_FILE else request.payload.image
                if image is None or image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
                    raise ValueError('Expected a uint8 BGR frame')
                height,width = image.shape[:2]
                transform = make_letterbox_transform(ImageSize(width,height))
                started = time.perf_counter()
                tensor = _preprocess_bgr_image(image, transform)
                self.last_timings['preprocessSeconds'] = time.perf_counter()-started
                started = time.perf_counter()
                self._interpreter.set_tensor(self._input['index'],tensor)
                self._interpreter.invoke()
                output = self._interpreter.get_tensor(self._output['index'])
                self.last_timings['predictionSeconds'] = time.perf_counter()-started
            except Exception:
                return self._error(request,'INFERENCE_FAILED')
            try:
                started = time.perf_counter()
                decoder = decode_bus_detections if self.profile_name == 'coco-bus' else decode_bus_door_detections
                raw = decoder(output,transform=transform)
                detections = []
                for box in raw:
                    x,y = box.x1/width,box.y1/height
                    detections.append({'classId':box.class_id,'score':box.score,'bbox':{
                        'x':x,'y':y,'w':min((box.x2-box.x1)/width,1-x),
                        'h':min((box.y2-box.y1)/height,1-y)}})
                result = adapt_vision_result({'frameId':request.frame_id,'capturedAt':request.captured_at,
                    'imageSize':{'width':width,'height':height},'detections':detections},
                    request,self.model_info,self.profile['classes'])
                self.last_timings['conversionSeconds'] = time.perf_counter()-started
                return result
            except Exception:
                return self._error(request,'RESULT_CONVERSION_FAILED')

    def _error(self, request, code):
        return DetectionResult('1.0.0',request.source.value,DetectionStatus.ERROR,(),
            frame_id=request.frame_id,captured_at=request.captured_at,model_info=self.model_info,
            error=DetectionError(code,'TFLite frame processing failed'))
