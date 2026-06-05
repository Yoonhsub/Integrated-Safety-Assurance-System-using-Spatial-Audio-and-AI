## #36 구현 완료 보고

### 수정/추가 파일
- `apps/passenger_app/web/mobi_spatial_cue.js`
- `apps/passenger_app/web/index.html`
- `apps/passenger_app/pubspec.yaml`
- `apps/passenger_app/lib/src/services/spatial_cue_service.dart`
- `apps/passenger_app/lib/src/services/spatial_cue_service_web.dart`
- `apps/passenger_app/lib/src/services/spatial_cue_service_stub.dart`
- `apps/passenger_app/lib/src/services/mock_script_audio_service.dart`
- `apps/passenger_app/lib/src/mock_scenario/mock_script_lines.dart`
- `apps/passenger_app/lib/src/services/audio_haptic_cue_service.dart`
- `apps/passenger_app/lib/src/pages/v3_guidance_page.dart`
- `apps/passenger_app/lib/src/widgets/mock_control_panel.dart`
- `apps/passenger_app/assets/mock_voice/.keep`
- `docs/rw/AJH_ISSUE36_COMPLETION_REPORT.md`

### 구현한 cue pattern
- normal: target bus 접근용 단일 Web Audio beep. 거리 가까울수록 gain 증가, interval 감소.
- warning: wrong bus 경고용 교대 pitch beep. 좌측 pan anchor 사용.
- alarm: geofence/danger 경고용 빠른 2-tone alarm.
- missed: missed bus 상황용 낮은 pitch cue.

### 구현한 scriptLineId
- `mock_start`
- `arrive_at_stop`
- `bus_approaching`
- `bus_stopped`
- `geofence_warning`
- `wrong_bus_warning`
- `boarding_prompt`
- `boarded_success`
- `missed_bus`
- `signal_lost`

### 통화 모드 처리
- 탑승 성공: Live 통화 발화에 `탑승`, `탔다`, `탔어`, `완료`, `성공` 계열 표현이 들어오면 `boarded_success` 고정 대사 우선 재생 후 cue 종료.
- 탑승 실패: `놓쳤`, `놓침`, `지나갔`, `실패` 계열 표현이 들어오면 `missed_bus` 고정 대사와 missed cue 재생.
- 다시 말하기: `다시`, `반복`, `한번 더` 계열 표현이 들어오면 마지막 scriptLineId/문장을 재생.

### 하드웨어 검증 결과
- 비컨 ID/역할: 실측 후 기입. 예) beacon A = target, beacon B = wrong.
- 골전도 이어폰 테스트: 실측 후 기입 예정.
- 좌우 pan 테스트: 실측 후 기입 예정.
- near/mid/far 테스트: 실측 후 기입 예정.
- target/wrong 테스트: 실측 후 기입 예정.
- 사람 기반 테스트: 실측 후 기입 예정.

### 검증 기기
- iOS: 실측 후 기입.
- Android: 실측 후 기입.

### VM 배포 결과
- 배포 시각: 배포 후 기입.
- curl 200 여부: 배포 후 기입.

### 남은 문제/한계
- 실제 mp3 파일은 포함하지 않고 `assets/mock_voice/` 경로와 fallback TTS를 구현했다. mp3를 추가하면 같은 scriptLineId 파일명으로 우선 재생된다.
- 실제 Web Audio pan/gain 체감은 골전도 이어폰, 브라우저, OS 오디오 정책에 따라 다를 수 있어 실기기 검증값을 추가해야 한다.
- 실제 beacon ingest/latest 연동 결과는 #35 backend 배포 상태와 하드웨어 측정 후 보고서에 보완해야 한다.
