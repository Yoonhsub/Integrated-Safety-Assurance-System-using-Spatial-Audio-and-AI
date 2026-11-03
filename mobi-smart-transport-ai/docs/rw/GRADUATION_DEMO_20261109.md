# 2026-11-09 졸업 프로젝트 Android 시연 기준

> 최신 실행·복구·백업 절차와 현재 상태는 [Android 시연 Runbook](ANDROID_DEMO_RUNBOOK_20261109.md)을 따른다. 아래 초기 준비 표는 11/2 당시 기록이며 이후 실기기 결과를 대체하지 않는다.

기준일: 2026-11-02. 날짜는 개발 목표이며 실제 완료를 보증하지 않는다.
최소 수락: 한 Android 기기에서 로그인 → Guidance → 카메라 → 실제 TFLite → 기존 Backend → 결과 갱신을 반복하고, 확인된 정보의 한국어 안내/STOP/Live Hold를 재현한다.
새 인증/Lease/ACK 설계, 다중 Worker, 임의 모델 교체는 하지 않는다.

## 상태 기준

- DONE: 실제 목표 Android 환경에서 실행 증거 확보.
- READY: 구현/빌드는 있지만 해당 Android 실행 증거 미확보.
- BLOCKED: 실제 연결 누락·오류 또는 필요한 설정/장비 부재로 다음 실행 불가. 외부 전제와 코드 결함을 구분한다.
- DEFERRED: 11/9 핵심 시연이 안정될 때까지 작업하지 않음.

| 범위 | 상태 | 근거와 다음 동작 |
|---|---|---|
| 일반 Passenger APK / 모델 / native library | READY | 일반 debug 빌드와 실제 APK 내용 확인. 실기기 카메라/TFLite는 미실행 |
| 실제 Firebase → Guidance (PC) | DONE | 승인된 승객 역할 반영 후 실제 Firebase ID Token으로 Guidance HTTP 200 확인. 당시 저장소는 로컬 메모리 |
| Android 로그인 실행 | READY | 실제 설정을 반영한 일반 APK 준비. Android 기기 로그인은 미검증 |
| Guidance 세션 시작·복구 | READY | 최초 실패 후 새로고침이 세션을 다시 생성하도록 수정, 실제 Widget + Fake 의존성에서 재현 |
| Camera → 본인 세션 Binding → Backend → 표시 | READY | 기존 로컬 Dart/HTTP 경로, 현재 Camera/모델 연결 및 APK 구현. 실기기 결과/FPS는 미확보 |
| Android 한국어 TTS Adapter | READY | flutter_tts 경로와 localaudio 진입점 존재. 실제 엔진/한국어 음성/청취는 미확보 |
| Android Stereo Cue 시험 앱 | READY | localaudio 전용 Activity + NativeDirectionalCueOutput 있음. 실기기 Runtime/청취는 미확보 |
| 일반 Passenger의 Native Cue 연결 | READY | 기존 엔진을 공통 main 소스로 이동해 MainActivity에도 등록. 로그인 후 모드 선택 화면의 수동 음성·방향 확인에서 사용. 실기기 재생은 미검증 |
| Android 관찰 결과 → 정보성 음성 | BLOCKED(미연결) | 현재 camera Preview는 오디오 자동 생성 금지. Android source가 기존 Vision 음성 허용 경로에 포함되지 않음 |
| BLE 목표 버스 | BLOCKED(앱 통합 미완료) | FlutterBlueBeaconScanner는 존재하나 일반 Passenger 화면의 실제 scanner/목표 비콘 ID 연결이 확인되지 않음. 하드웨어 필요 |
| bus_door 고도화 / Head Tracking | DEFERRED | 기존 모델/코드는 보존하되 11/9 핵심 시연 전 추가 개발하지 않음 |

실제 Firebase 토큰의 PC HTTP 성공은 확인했지만 새로운 Android DONE은 아직 없다. 기존 PC/Chrome 성공을 Android DONE으로 승격하지 않는다.

## 즉시 수행 / 현재 수정

1. 서버 최초 연결 실패 후 빈 sessionId로 상태 조회하던 새로고침을 재연결 동작으로 수정.
2. 카메라 버튼 연속 입력 시 같은 화면이 중복 열리지 않도록 진입 guard 및 버튼 비활성화 추가.
3. 일반 Android Manifest에 기존 flutter_tts가 요구하는 TTS_SERVICE 조회 항목 추가. 오디오 구현 변경 없음.
4. 기존 Android Audio 9개 파일, Lease/Fencing/Binding Revision, 시험 APK 격리, guidanceEligible=false 보존.
5. 공개 설정 파일 경로가 도착하면 아래 도구로 실제 설정을 넣은 일반 APK 준비. 구성 검사/빌드는 Firebase에 접속하지 않는다.

## 실행 명령

저장소 루트에서, 사용자에게 전달받은 실제 Android 파일 경로를 사용한다. 서비스 계정/관리자/장기 Producer 비밀은 넣지 않는다.

```powershell
python scripts/prepare_passenger_android.py --google-services C:/outside/google-services.json --backend-url http://127.0.0.1:8000
python scripts/prepare_passenger_android.py --google-services C:/outside/google-services.json --backend-url http://127.0.0.1:8000 --flutter "C:/Flutter SDK/flutter/bin/flutter.bat" --build
```

기기 연결 시에만 한 번 확인하고 USB reverse/설치한다:

```powershell
adb devices -l
adb reverse tcp:8000 tcp:8000
adb install -r apps/passenger_app/build/app/outputs/flutter-apk/app-debug.apk
```

실제 Firebase 인증/저장소의 실행 승인이 있어야 일반 앱 로그인과 실제 서버 흐름을 테스트한다.
서버는 기존 FastAPI, 단일 Worker, PC loopback:8000, MOBI_PASSENGER_CAMERA_PREVIEW=1을 사용한다.
기기가 없으면 반복 검사하지 않고 DEVICE_NOT_CONNECTED로 기록한다.
앱 사용자에게 관리자 Binding, JSON 파일 선택, 모델 파일 선택을 요구하지 않는다.

## 기존 오디오를 별도로 확인하는 절차

일반 앱 통합 전, 기존 오디오 구현의 실제 Android 동작부터 분리 확인한다:

```powershell
flutter build apk --debug --no-pub --target lib/local_android_audio_main.dart --dart-define=MOBI_ANDROID_LOCAL_AUDIO=true
```

일반 APK를 별도 경로에 보존한 뒤 생성된 localaudio APK를 설치한다. 이 시험 앱은 오프라인이다.
한국어 TTS 엔진/로컬 한국어 음성 존재 확인 → 사용자가 테스트 버튼을 누름 → 3초 넘는 문장 전체 청취 → STOP → Live Hold → LEFT/CENTER/RIGHT → Cue→TTS → 세션/페이지 종료.
콜백과 사람 청취는 따로 기록한다. Shokz는 미디어 출력으로 실제 연결한 장치를 적는다.
일반 앱에 Cue를 연결할 때 이 엔진과 Coordinator를 재사용하고 복사한 두 번째 엔진은 만들지 않는다.
현재 일반 앱의 방향 Cue가 이미 연결됐다고 보고하지 않는다.

## 11/9까지 집중 순서

- 11/2~11/3: Android 공개 설정 경로·실기기 확보, 첫 실제 로그인/프레임/Backend 표시. 초기 장애만 수정.
- 11/3~11/4: 한국어 TTS/STOP/Live Hold 실기기 확인, 기존 Native Cue의 일반 앱 등록과 출력 경로 최소 연결.
- 11/5: 기존 BLE scanner를 목표 비콘 ID/버스 선택에 연결. 실제 비콘 없이 목표 버스 확인 성공이라 하지 않음.
- 11/6: 확인된 현재 bus 관찰에 대한 사용자 허용 정보성 안내 연결. 일반 이미지 bus 검출을 목표 노선/출입문/거리/승차 가능으로 바꾸지 않음.
- 11/7: 핵심 동작이 안정되면 기능 추가 중단. bus_door/Head Tracking 계속 보류.
- 11/8: 동일 기기·APK·서버로 5회 반복 시연, 중지/재시작/서버 복구/세션 종료 재현, 성공한 APK 해시와 실행 순서 고정.
- 11/9: 검증한 구성으로 시연. 미검증 위험 안내는 켜지 않음.

11/3까지 기기/설정이 없으면 핵심 실기기 안정화 시간이 부족해질 위험이 크다. 이 경우 시연 범위를 줄여야 하며 Android 완료를 주장하지 않는다.

## 시연 증거 최소 단위

기종/OS, APK SHA256, 입력이 실물 버스인지 버스 사진인지, 모델 SHA256/threshold,
최소 30개 실제 frameId, 실제 native 추론 ms/처리 FPS/전송 수/화면 갱신 지연,
STOP/서버 재연결/세션 종료 후 잔여 처리, TTS 전체 청취 및 장치 종류를 기록한다.
버스 사진을 카메라로 촬영하는 시연은 사진 입력이라고 명시한다. Fixture DetectionResult를 실제 추론으로 제시하지 않는다.
방향의 실제 근거가 없으면 Cue는 고정 방향 시험으로 분리 표시하며 사용자의 이동을 지시하지 않는다.


## 2026-11-02 후속 진행

- 403 원인: 승인된 계정에 mobi_role이 없었음. 해당 UID 하나에 passenger 역할만 추가하고 재조회 확인.
- 실제 Firebase 로그인 → Guidance HTTP 200 확인 완료. 이 증거는 Android 로그인/RTDB 저장 성공을 뜻하지 않음.
- Native Stereo 엔진 본문을 바꾸지 않고 LocalAudioActivity에서 main/LocalStereoCue.kt로 이동했다. 시험 Activity의 격리 검사/생명주기 래퍼도 유지했다.
- 일반 MainActivity가 같은 엔진을 사용한다. 기본 자동 재생은 없고 로그인 뒤 모드 선택 화면에서 수동 오디오 확인에 진입한다.
- 기존 오디오 확인 페이지에는 선택적 실제 로그아웃 콜백만 연결했다. 일반 앱에서는 음향 중지 → 기존 Lease 회수 시도 → 현재 auth epoch가 맞으면 Firebase 로그아웃한다. 별도 오프라인 시험 앱은 기존 동작을 유지한다.
- 일반 APK에 실제 Firebase 설정/Native Cue를 포함해 빌드 완료, 기존 관련 테스트 58 PASS.
- 현재 loopback:8000 서버는 임시 로그인 페이지를 종료하고 기존 app.main:app으로 전환했다. 제공된 실제 프로젝트/RTDB URL/기존 ADC를 사용하며 Mock 인증은 없다. health의 자격 준비 메타데이터만 확인했고 DB 권한·쓰기 사전 테스트는 하지 않았다.
- 기기가 연결되면 이 일반 APK를 설치하고 adb reverse 후 카메라/추론/전송 및 실제 오디오 재생을 확인한다. 방향 버튼은 검증용 고정값이며 실제 버스 방향을 의미하지 않는다.


## 2026-11-03 일반 Android Guidance 오디오 연결

- 기존 실기기 증거: Galaxy Z Flip5에서 로그인, 카메라 Preview/검출 결과, Backend 서버 수신 시각/frameId 갱신을 사용자 확인. 스피커로 별도 음성 화면의 TTS/Cue→TTS/STOP/Live Hold 확인. 일반 Guidance 이벤트의 실제 청취나 Shokz 방향 정확도까지 입증한 것은 아니다.
- 일반 Android Guidance는 기존 NativeDirectionalCueOutput + FlutterSpeechEngine(로컬 한국어 음성, native focus) + SpatialVerificationEngine + SpeechPriorityCoordinator를 조합해 사용한다. 새 엔진/상태 머신은 없다. Web 경로는 기존 출력을 유지한다.
- 세션 생성 성공 때 한 번만 시작 안내를 재생한다. 일반 Android 안내 응답은 외부 음성 생성 대신 같은 로컬 TTS를 사용한다. 서버 정보성 이벤트는 기존 소유권/generation/중복/admission 검사를 통과하고 사용자가 음성 스위치를 켠 경우에만 출력한다.
- 일반 Guidance에 음성 중지(STOP)와 안내 일시 정지(Live Hold)를 연결했다. 서버 요청 중에도 STOP 가능. Hold 해제는 과거 이벤트를 재생하지 않는다. 카메라 진입/백그라운드/로그아웃/reset/페이지 종료는 기존 취소 경로를 사용한다.
- 신뢰할 실제 방향 출처가 없으므로 일반 이벤트는 TTS-only다. Native LEFT/CENTER/RIGHT와 Cue→TTS는 기존 명시적 로컬 방향 검증 계약에서만 사용한다. 일반 엔진에서는 직접 @spatial 시험 명령을 차단한다. Vision preview guidanceEligible=false 유지, 위험 안내/자동 Cue/자동 Vision 음성은 추가하지 않았다.
- 정보성 안내 admission TTL 3초와 재생 watchdog 30초는 변경하지 않았다. 늦은 callback, AudioShutdown, quarantine, lease release 정책도 유지한다.
- 이번 상태는 GUIDANCE_AUDIO_READY로 코드/빌드 검증 후 판정한다. 최종 일반 Guidance에서 전체 문장/STOP/Hold/페이지 종료/다시 진입의 실기기 청취는 다음 기기 연결 때 확인한다. 기존 별도 음성 화면 성공으로 대체하지 않는다.
- 다음 P0: 기존 BLE Scanner의 실제 호출 위치와 목표 버스 식별 결과를 Guidance에 최소 연결. BLE 코드나 출처 정책은 이번 작업에서 변경하지 않았다. BLE 실물 수신 없이 목표 버스 식별 PASS로 보고하지 않는다.


## 2026-11-03 BLE → 일반 Guidance 로컬 연결

- 기존 FlutterBlueBeaconScanner를 일반 Guidance에서 수동 시작/중지한다. Android BLE 권한은 설치된 플러그인의 기존 요청 처리를 사용한다. 스캔 시간은 기존 10초이며, 수신 없음/실패/완료/신호 소실을 구분한다. 백그라운드/카메라 진입/목표 변경/reset/로그아웃/페이지 종료 시 정리한다.
- 현재 실제 비콘→버스 등록 데이터 및 등록 API가 없다. 사용자가 시연용 비콘 ID/버스 매핑 미준비라고 확인했다. 기존 /api/v3/beacon/ingest는 관리자 시험용이며 실제 차량을 식별하지 않으므로 일반 승객에게 권한을 열거나 해당 경로로 위장 전송하지 않았다.
- 일반 앱은 기존 Guidance targetBusId/selectedRouteNo를 표시하고 실제 BLE 수신을 보여 주되, 목표 버스는 미확인으로 유지한다. 이름/RSSI/노선만으로 차량을 확정하지 않으며 방향 Cue·거리·승차 지시를 생성하지 않는다.
- 명시적 LocalGuidanceRuntime의 Mock scanner + 기존 BeaconIngestIdentity fixture에서만 목표 버스 일치를 검증한다. 테스트 입력 표시와 검증용 문구를 사용해 기존 SessionGuidanceAudio→SpeechPriorityCoordinator→Native TTS 경로를 호출한다. 신규 오디오 엔진은 없다.
- 같은 세션/목표 버스의 반복 안내를 억제한다. STOP/Live Hold/이전 세대 callback은 기존 오디오 guard를 따르며, Hold 해제 후 과거 감지를 재생하지 않는다. 신호 소실은 기존 센서 정책과 같은 5초를 사용한다. 안내 admission 3초/playback watchdog 30초는 유지한다.
- 다음 실기기 검증: 근처 기기 권한 허용/거부, Bluetooth 꺼짐, 실제 광고 수신, 스캔 중지/재시작, 화면/세션 종료. 실제 목표 버스 식별 및 음성은 등록 비콘 ID와 차량/노선 매핑의 운영 출처 연결 후 별도로 수락한다. Mock 성공을 DEVICE_BLE_GUIDANCE_PASS로 보고하지 않는다.
- 현재 판정은 PARTIAL: 스캔·화면·Mock 식별→TTS는 준비됐으나 실제 목표 버스 매핑 연결이 남았다. 기존 Firebase/Camera/TFLite/Backend/Native Audio 구현은 변경하지 않는다.


## 2026-11-03 실제 BLE ↔ 로컬 시연 버스 매핑 경로

실제 시연 비콘 ID/버스 등록 데이터가 아직 제공되지 않아 실제 등록은 0건이다. 기존 관리자 전용 Beacon ingest API 권한은 변경하지 않는다. 아래 경로는 로컬 시연 설정이며 실제 운행 차량 등록 서비스가 아니다.

- 식별 방식: 기존 FlutterBlueBeaconScanner가 읽는 ScanResult.device.remoteId.str. Android에서는 기기의 MAC 형식 주소를 사용한다. 광고 이름/노선명/RSSI를 식별값으로 대신 쓰지 않는다. 제조사 UUID/manufacturer data 파서는 이번에 추가하지 않는다.
- 파일: apps/passenger_app/config/ble-local-demo.example.json. schemaVersion=1, identifierField=android.remoteId, entries=[]가 기본값이다. 실제 값을 확보한 후 파일을 복사하고 각 항목에 beaconId(MAC), busId(현재 Guidance 목표 버스 ID와 정확히 동일), routeNo(현재 선택 노선과 동일)를 넣는다. 임의 예시 MAC/차량 ID를 실제 등록값으로 배포하지 않는다.
- 실제 ID 확인: 일반 Guidance에서 BLE 스캔 시작 → 수신 식별값 확인을 펼친다. 표시된 remoteId를 비콘 제조사 앱/설정 및 비콘 전원 ON/OFF와 대조한다. 주변 기기의 최근 주소가 곧 시연 비콘이라는 의미는 아니다. 주소가 회전하는 기기는 고정 식별 방식 확정 전까지 목표 식별에 사용하지 않는다.
- 빌드: python scripts/prepare_passenger_android.py --google-services <기존 Android 공개 설정 경로> --backend-url http://127.0.0.1:8000 --ble-demo-mapping <실제 값을 넣은 로컬 시연 매핑 JSON 경로> --build --flutter <flutter.bat 경로>. 도구가 일반 main.dart debug 빌드에 MOBI_BLE_LOCAL_DEMO_MAPPING만 추가한다. 이 설정은 인증 권한/토큰/관리자 자격이 아니며 실제 Firebase 로그인/기존 세션을 계속 사용한다.
- 사용: 로그인 → 실제 Guidance에서 목표 버스/노선 선택 → BLE 스캔. 등록된 동일 주소/차량 ID/노선이 맞을 때만 로컬 시연 매핑 일치 상태와 정보성 TTS를 출력한다. 다른 차량과 미등록 주소는 별도 상태로 표시한다. 매핑을 생략하거나 잘못 설정하면 식별을 활성화하지 않는다. profile/release에서는 이 시연 설정을 무시한다.
- 출처 표시: 실제 BLE + 로컬 시연 매핑 / 운행 차량 등록 아님. 음성도 로컬 시연 매핑 기준임을 명시한다. Mock BLE 입력과 별도로 표시한다. 승차 가능/거리/출입문 방향/Cue/위험 Guidance는 만들지 않는다.
- 중복/소실/수명: 기존 세션 범위 중복 억제, 5초 신호 소실, 3초 admission과 30초 playback watchdog을 유지한다. STOP/Live Hold, 목표 변경/reset/로그아웃/페이지 이탈 정리는 같은 Coordinator와 스캐너를 사용한다. 스캐너를 먼저 중지하고 구독을 정리한다.
- 검증 입력은 기존 ScanResult 파서에 넣은 명시적 Fixture다. 실제 비콘/Android 장치 수신과 실제 청취는 REAL_BLE_DEVICE_NOT_VERIFIED다. 다음 작업은 실제 주소/차량 ID/노선 입력 후 이 APK 경로로 전체 시연을 통합하는 것이며 새 관리 시스템 구현은 필요하지 않다.


## 2026-11-03 Camera 화면 위치 음향 시연 연결

기존 위험 Guidance를 활성화하지 않고 일반 Passenger 버스 카메라에 사용자 opt-in 정보성 음향을 연결했다. 실제 LocalObservation.toDetectionResult의 className/confidence/정규화 bbox를 읽고 화면 중심 가로 3등분으로 기존 Stereo Cue→일반 한국어 TTS를 요청한다. 동일 Coordinator와 Native 엔진을 재사용하며 Backend/SafetyInterpreter/모델/클래스 매핑/BLE/기존 TTS 구현은 바꾸지 않았다. direction provenance는 local CAMERA_SCREEN_INFORMATIONAL_PREVIEW이며 실제 공간/출입문/목표 버스 정보가 아니다. 카메라 화면에 기본 OFF 스위치, STOP, Live Hold, frameId/bbox/방향/완료 진단을 제공한다. 실제 단말 청취는 아직 NOT_VERIFIED이며 코드·빌드 결과는 VISION_SPATIAL_AUDIO_READY 범위로만 보고한다. 최신 APK와 수동 절차는 Runbook 9절을 따른다.


### 2026-11-03 휴대폰 단독 시연 경로
일반 앱 첫 화면에 LOCAL_DEMO를 추가했다. 로그인·PC·Backend·ADB reverse 없이 기존 Camera/TFLite/화면 결과/Native Cue/TTS를 재사용한다. 기본 음향 OFF이며 사용자가 켠다. 온라인 Firebase/Lease/Guidance 인증은 그대로 별도 입구로 유지한다. 실제 USB 제거 후 청취는 NOT_VERIFIED. 상세 실행 순서는 ANDROID_DEMO_RUNBOOK_20261109.md 10절 참조.
