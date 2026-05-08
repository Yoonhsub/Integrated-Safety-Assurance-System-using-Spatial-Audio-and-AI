# Bus Door Detection YOLO Fine-tuning

## 개요

본 프로젝트는 시각장애인의 버스 탑승 보조를 위해 버스 출입문을 인식하는 AI 비전 모델을 학습하는 것을 목표로 한다.

정류장 내 모든 장애물을 탐지하는 방식은 정보 과부하를 유발할 수 있으므로, 본 프로젝트에서는 버스 탑승 과정에서 필요한 핵심 정보인 버스 출입문 위치 인식에 집중한다.

## 학습 방식

Roboflow를 활용하여 버스 출입문 이미지를 `bus_door` 클래스로 라벨링하고, YOLO 형식으로 export한다. 이후 Colab에서 COCO pretrained YOLO 모델을 불러와 `bus_door` 데이터셋으로 파인튜닝한다.

## 학습 파이프라인

Roboflow 라벨링 및 데이터셋 생성  
→ YOLO 형식 Export  
→ Colab에서 데이터셋 다운로드  
→ COCO pretrained YOLO 모델 파인튜닝  
→ bus_door 커스텀 모델 생성  
→ TFLite 변환

## 실행 파일

학습 및 변환 코드는 `notebooks/bus_door_yolo_training.ipynb`에서 확인할 수 있다.

## 향후 계획

- 실제 정류장 환경 이미지 추가 수집
- 영상 테스트를 통한 프레임 단위 탐지 안정성 확인
- TFLite 변환 후 Flutter 앱 적용
- 실시간 카메라 환경에서 FPS, 오탐, 미탐 검증
