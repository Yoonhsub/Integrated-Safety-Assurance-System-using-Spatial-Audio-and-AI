"""Offline contract/decoder tests; no downloaded runtime/model required."""
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4
import numpy as np
import pytest
from jsonschema import Draft202012Validator, FormatChecker
from ai_vision.pipelines.tflite_vision_provider import adapt_vision_result, TFLiteVisionProvider
from ai_vision.pipelines.tflite_decoding import (make_letterbox_transform, decode_bus_door_detections,
    decode_bus_detections, _preprocess_bgr_image, _model_box_to_source)
from ai_vision.pipelines.detection_result import ImageSize, ModelInfo, DetectionStatus
from ai_vision.pipelines.vision_input import VisionInferenceRequest, VisionInputSource, FrameImagePayload
from ai_vision.pipelines.vision_provider import create_vision_provider, ProviderConfigurationError


def data():
    req=VisionInferenceRequest(str(uuid4()),'2026-10-13T01:00:00+00:00',VisionInputSource.VIDEO_FILE,
        FrameImagePayload(np.zeros((101,200,3),np.uint8)),0)
    payload={'frameId':req.frame_id,'capturedAt':req.captured_at,'imageSize':{'width':200,'height':101},
        'detections':[{'classId':'bus_door','score':0.9,'bbox':{'x':0.2,'y':0.1,'w':0.3,'h':0.8}}]}
    return req,payload


def test_adapter_schema_and_original_identity():
    req,payload=data()
    result=adapt_vision_result(payload,req,ModelInfo('tflite','bus-door','v1'),('bus','bus_door'))
    schema=json.loads((Path(__file__).resolve().parents[3]/'packages/shared_contracts/api/vision_detection.response.schema.json').read_text(encoding='utf-8'))
    Draft202012Validator(schema,format_checker=FormatChecker()).validate(result.to_dict())
    assert result.captured_at==req.captured_at and result.frame_id==req.frame_id
    assert result.source=='video_file' and result.detections[0].class_name=='버스 문'

@pytest.mark.parametrize('field,value',[('score',float('nan')),('score',1.1),('score',True),('classId','pole')])
def test_invalid_detection_fails(field,value):
    req,payload=data();payload['detections'][0][field]=value
    with pytest.raises(ValueError): adapt_vision_result(payload,req,ModelInfo('tflite','x'),('bus','bus_door'))

@pytest.mark.parametrize('field,value',[('x',-0.1),('w',0),('w',0.9),('h',float('inf'))])
def test_invalid_bbox_fails(field,value):
    req,payload=data();payload['detections'][0]['bbox'][field]=value
    with pytest.raises(ValueError): adapt_vision_result(payload,req,ModelInfo('tflite','x'),('bus_door',))

@pytest.mark.parametrize('field',['frameId','capturedAt'])
def test_retimed_or_different_frame_fails(field):
    req,payload=data();payload[field]='changed'
    with pytest.raises(ValueError): adapt_vision_result(payload,req,ModelInfo('tflite','x'),('bus_door',))


def test_model_identity_and_explicit_profile(tmp_path):
    p=tmp_path/'wrong.tflite';p.write_bytes(b'not the released model')
    with pytest.raises(ProviderConfigurationError): create_vision_provider('tflite',model_path=p,tflite_profile='bus-door')
    with pytest.raises(ProviderConfigurationError): create_vision_provider('tflite',model_path=p)


def test_classwise_nms_and_coco_mapping():
    t=make_letterbox_transform(ImageSize(640,640))
    output=np.zeros((1,6,2));output[0,:4,:]=np.array([[.5,.5],[.5,.5],[.4,.4],[.4,.4]])
    output[0,4,:]=.9;output[0,5,:]=.8
    result=decode_bus_door_detections(output,transform=t)
    assert [d.class_id for d in result]==['bus','bus_door']
    coco=np.zeros((1,84,1));coco[0,:4,0]=(.5,.5,.4,.4);coco[0,9,0]=.9
    assert decode_bus_detections(coco,transform=t)[0].class_id=='bus'
    with pytest.raises(ValueError): decode_bus_door_detections(coco,transform=t)
    output[0,5,0]=1.1
    with pytest.raises(ValueError): decode_bus_door_detections(output,transform=t)


def test_rgb_normalization_and_odd_padding_roundtrip():
    image=np.zeros((101,200,3),np.uint8);image[:,:,2]=255
    t=make_letterbox_transform(ImageSize(200,101));tensor=_preprocess_bgr_image(image,t)
    assert tensor.dtype==np.float32 and tensor.shape==(1,640,640,3)
    assert tensor[0,int(t.pad_y),0].tolist()==[1,0,0]
    box=_model_box_to_source(center_x=.5,center_y=(t.pad_y+101*t.scale_y/2)/640,
        width=1,height=101*t.scale_y/640,transform=t)
    assert box==pytest.approx((0,0,200,101))


def test_warmup_failure_and_inference_error():
    import threading
    p=object.__new__(TFLiteVisionProvider);p._lock=threading.RLock();p._input={'index':0};p.last_timings={}
    p.model_info=ModelInfo('tflite','test')
    def fail(*args): raise RuntimeError('runtime failure')
    p._interpreter=SimpleNamespace(set_tensor=fail)
    with pytest.raises(ProviderConfigurationError): p.warm_up()
    req,_=data();result=p.infer(req)
    assert result.status is DetectionStatus.ERROR and result.detections==()
    assert result.frame_id==req.frame_id and result.captured_at==req.captured_at
