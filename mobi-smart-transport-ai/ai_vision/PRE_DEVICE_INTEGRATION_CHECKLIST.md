# 실기기 전 통합 체크리스트

이 문서는 Android 실제 기기 카메라 검증을 시작하기 전까지 완료할 수 있는 준비 항목을
한 곳에 모은 것이다. 앱·공용 계약·음성 정책의 코드는 각 담당 영역에서 작성한다.

## AI Vision에서 완료한 항목

- [x] `bus`·`bus_door` 학습 모델과 Android float32 TFLite 모델 준비
- [x] 모델 파일을 Git LFS로 관리하고 SHA-256 기록
- [x] Android 입력 `[1,640,640,3]` 및 출력 `[1,6,8400]` 규격 확인
- [x] 버스와 버스 문의 클래스별 NMS·방향·상대 거리·변화 상태 처리 준비
- [x] 실제 공개 테스트 이미지에서 TFLite의 버스·문 검출 확인
- [x] Context·Audio 연동용 정책 없는 안내 후보 fixture 제공
- [x] 자동 검사 74개 통과

## Android 담당자가 연결할 항목

- [ ] `yolo11n_bus_door_v1_float32.tflite`를 앱 asset에 포함
- [ ] 후면 카메라 프레임을 RGB float32 letterbox 입력으로 변환
- [ ] 출력 채널 4를 `bus`, 채널 5를 `bus_door`로 해석
- [ ] 같은 클래스끼리만 NMS 적용
- [ ] 검출 결과를 AI Vision 안내 후보 형식으로 넘김

세부 전처리·후처리 규칙은 [Android TFLite 연결 인계서](ANDROID_TFLITE_HANDOFF.md)를
따른다.

## Context·Audio 담당자가 연결할 항목

- [ ] `pipelines/fixtures/bus_door_guidance_candidate.json`으로 입력 흐름 확인
- [ ] 후보의 `direction`, `relativeDistance`, `motion`을 사용자 상태와 결합
- [ ] 음성 문장·공간 음향·우선순위·반복 억제 정책 결정
- [ ] `bus`와 `bus_door`가 함께 올 때 중복 안내하지 않도록 처리

AI Vision 후보에는 위험도나 음성 문장이 없다. 이는 Context·Audio의 정책 영역이다.

## 팀 합의 후 남는 항목

- [ ] 후보 payload를 정식 공용 계약으로 등록
- [ ] 실제 기기 카메라에서 인식률·지연 시간·발열 확인
- [ ] 실제 정류장에서 낮·밤·흔들림·거리 변화에 맞게 임계값과 분석 주기 조정
- [ ] 국내 장애물 데이터가 충분해진 뒤 기둥·나무 등 보류 클래스 재학습
