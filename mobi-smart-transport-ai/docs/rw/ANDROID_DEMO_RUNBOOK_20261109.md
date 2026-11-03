# 11월 9일 Android 시연 실행·복구 절차

기준: 2026-11-03 / feat/tflite-v2-integration / HEAD ba5bc5ae686d1f8a7f06b6c884e8066221f7d881 + 미커밋 변경. 이 문서는 기존 기능을 실행한다. Firebase/IAM/ADC 설정, 코드, 사용자 Claims를 바꾸지 않는다. 기존 scripts/local_demo.ps1은 Firebase Emulator 전용이므로 이번 일반 Android 시연과 혼용하지 않는다.

## 준비물과 고정 산출물

- Windows PC, 인터넷(Firebase 로그인·기존 Backend 저장소), 전원, 데이터 전송 가능한 USB 케이블.
- Galaxy Z Flip5 SM-F731N(Android 16/API 36): 이전 실기기 확인 기종. USB 디버깅과 이 PC 허용 상태. 다른 기기는 미검증이다.
- 실제 승객 계정과 비밀번호를 사용자가 직접 입력한다. 비밀번호/토큰은 채팅·스크립트·로그에 기록하지 않는다.
- 기존 ADC와 API Python 가상환경, Android SDK/ADB/aapt. 새 ADC 로그인·권한 테스트·프로젝트 변경은 수행하지 않는다.
- 버스 양성 검출을 보이려면 승인된 실제 버스 입력 또는 버스 사진을 준비한다. 사진을 촬영하면 사진 입력이라고 설명한다. bus_door 성공을 약속하지 않는다.
- Shokz OpenRun Pro 2는 휴대폰의 미디어 출력으로 직접 연결한다. 기존 오디오 실기기 청취는 휴대폰 스피커 기준이며 Shokz/좌우 정확도는 아직 미검증이다.
- 실제 비콘은 아직 미준비다. 없으면 BLE는 미등록/미감지로 시연하고 목표 버스 식별 성공을 주장하지 않는다.

| APK | SHA256 | 증거 범위 |
|---|---|---|
| android-device-runtime-20261102/mobi-passenger-device-debug.apk | b0f8e3a484faabeefc34b926f938a0f1b3c03bd4514236c2437a4f94b15eea5e | 실제 Android 로그인, 카메라→Backend→화면 갱신 사용자 확인, 별도 음성 화면 스피커 확인본 |
| ble-mapping-20261103/mobi-passenger-ble-mapping-debug.apk | 9fed57e5e5f84d8b9012e80b2360538e288fceb6e0dc50bd5d91a28030a2cb7f | 이전 Guidance Audio/BLE READY 보존본. BLE 등록 0건 |
| standalone-passenger-20261103/mobi-passenger-standalone-debug.apk | 79049294311fd37c800cfa086dff0203c5bade9403f32c43a01fe5f1870e4d0c | 최신 휴대폰 단독 LOCAL_DEMO READY. USB 제거 후 실기기 수락 대기 |
| vision-screen-audio-20261103/mobi-passenger-vision-screen-audio-debug.apk | 37e38452536172782607eed6d9e29983909464fd3d516cffadfef1a5ef40b31d | 이전 화면 위치 Cue→TTS 통합 READY. 실제 새 경로 청취 미검증, BLE 등록 0건 |

각 경로의 공통 증거 루트는 C:/Users/lucid/.codex/visualizations/2026/10/05/01a10b2b-8699-7732-bb48-e2edbcfeaef6 이다. 최신 APK가 이전 실기기 증거를 자동 승계하는 것은 아니다. 문제 시 확인본 APK로 되돌릴 수 있지만, 기능 범위도 그 버전으로 줄어든다. 자동 재빌드/자동 교체는 하지 않는다.

## 1. PC 준비 점검 — 폰 없이 가능

PowerShell을 열고 실제 작업 중인 저장소를 선택한다.

```powershell
Set-Location -LiteralPath 'C:/Users/lucid/.codex/worktrees/tflite-v2-integration/Integrated-Safety-Assurance-System-using-Spatial-Audio-and-AI/mobi-smart-transport-ai'
$demo = Join-Path (Get-Location) 'scripts/android_demo.ps1'
$python = 'C:/Users/lucid/OneDrive/Desktop/capstones/Integrated-Safety-Assurance-System-using-Spatial-Audio-and-AI/mobi-smart-transport-ai/backend/api/.venv/Scripts/python.exe'
$evidence = 'C:/Users/lucid/.codex/visualizations/2026/10/05/01a10b2b-8699-7732-bb48-e2edbcfeaef6'
$apk = Join-Path $evidence 'standalone-passenger-20261103/mobi-passenger-standalone-debug.apk'
$sha = '79049294311fd37c800cfa086dff0203c5bade9403f32c43a01fe5f1870e4d0c'
& $demo -Action Check -BackendPython $python -Apk $apk
```

Check는 파일·APK 패키지/해시와 loopback health만 읽는다. 기기 조회, Firebase Admin 권한 테스트, 로그인, 설정 변경은 없다. Python/ADB가 없다고 나오면 기존 설치 경로를 -BackendPython/-Adb 인자로 지정한다. 환경을 새로 설치하지 않는다.

## 2. Backend — 첫 번째 PowerShell 창

```powershell
& $demo -Action Backend -BackendPython $python
```

기존 app.main:app을 127.0.0.1:8000, worker 1개로 실행한다. 원래 환경은 종료 시 복원하며 시스템 환경변수/ADC 파일은 변경하지 않는다. 이 창은 시연 중 열어 둔다. 종료는 Ctrl+C다.

| 이번 실행에만 적용하는 환경 | 값 |
|---|---|
| FIREBASE_PROJECT_ID | mobi-smart-transport |
| FIREBASE_DATABASE_URL | https://mobi-smart-transport-default-rtdb.asia-southeast1.firebasedatabase.app |
| FIREBASE_USE_ADC / FIREBASE_USE_MOCK | true / false |
| APP_ENV | staging |
| MOBI_PASSENGER_CAMERA_PREVIEW | 1 |
| FCM_ENABLED / FCM_USE_MOCK | false / true |

8000에 기존 서버가 있으면 새 서버를 겹쳐 띄우거나 알 수 없는 프로세스를 종료하지 않는다. Check로 확인하고 기존 서버 창을 사용한다. Emulator 관련 환경변수가 남은 터미널은 혼용하지 않는다. .env/외부 API 키를 스크립트가 출력하거나 덮어쓰지 않는다.

health의 firebaseMode=firebase-admin은 인증/저장 모드다. dataMode=mock이면 버스·경로 데이터는 Mock 모드이므로 실제 운행정보 성공이라고 설명하지 않는다. /__local/firebase-login은 과거 임시 페이지이며 이번 실행에 필요하지 않다. 앱에서 로그인한다.

## 3. USB 연결·설치·실행 — 두 번째 PowerShell 창

1번의 변수 선언을 두 번째 창에도 실행한다. 실제 폰을 연결한 경우에만 진행한다.

```powershell
& $demo -Action Device
& $demo -Action Install -Apk $apk -ExpectedApkSha256 $sha
& $demo -Action Launch
```

Device는 adb devices를 한 번 확인하고 승인된 기기가 정확히 하나일 때 reverse tcp:8000→tcp:8000을 설정한다. 여러 기기면 -Serial을 명시한다. 연결/승인이 없으면 종료하며 자동 재시도·Emulator 실행은 없다. 케이블은 시연 중 계속 연결한다.

Install은 일반 com.example.mobi_passenger_app 패키지와 지정한 해시를 확인하고 install -r로 갱신한다. 앱 데이터 삭제·자동 제거는 하지 않는다. 서명 충돌/다운그레이드 오류가 나면 설치를 멈추고 올바른 APK를 선택한다. 앱 데이터 초기화로 우회하지 않는다.

## 4. 핵심 시연 순서

1. 앱 로그인 → 모드 선택 → 실제 API 데이터 테스트 → 필요한 경우 안내 이름 설정 → 일반 Guidance 진입.
2. 최신 APK의 시작 안내를 듣는다. 세션 안전 정보 음성은 기존 정책상 기본 OFF이며, 검증된 세션 이벤트 안내가 필요한 경우에만 직접 켠다.
3. 버스 카메라 시작 → 카메라 시작 → 권한 허용. 모델은 포함된 asset에서 자동 준비된다.
4. Preview와 로컬 검출 클래스/confidence/bbox를 확인한다. 버스가 실제 검출되지 않았다면 버스 양성이라고 설명하지 않는다.
5. 아래 AI Vision 관찰 영역의 서버 수신 시각/frameId 연속 갱신을 확인한다. 로컬 오버레이만 보고 Backend 전달 PASS로 판정하지 않는다.
6. 카메라 중지 → 화면 정리와 서버 갱신 중지 → 재시작 → 새 frameId 갱신 확인.
7. 카메라를 종료하고 일반 Guidance에서 허용된 정보성 문장을 재생한다. 전체 문장 완료 → 음성 중지(STOP) → Live Hold 중지/새 안내 허용 → 이전 안내 재생 없음 확인.
8. 로그아웃/Guidance 종료 후 잔여 소리·전송이 없는지 확인하고 재진입한다.

일반 Guidance 음성 수락은 같은 화면을 세 번 새로 진입해 확인할 수 있다. 첫 진입에서는 “안내가 시작되었습니다. 목적지를 말씀하거나 입력해 주세요.”를 끝까지 듣는다. 두 번째 진입에서는 이 시작 안내 도중 STOP을 누른다. 세 번째 진입에서는 시작 안내 도중 Live Hold를 누르고, 새 안내 허용을 눌러도 중단된 문장이 다시 나오지 않는지 확인한다. 돌아가기/재진입은 사용자 동작이며 새 세션으로 처리한다. 없는 Safety Event나 임의 방향을 주입하지 않는다. 화면 rebuild만으로 문장이 다시 시작되면 오류로 기록한다.

Vision Preview는 guidanceEligible=false다. 카메라 검출만으로 위험 음성/출입문 방향/Cue를 자동 출력하지 않는다. 3초 freshness는 안내 시작 전 admission이며, 승인된 정보성 재생에는 기존 30초 watchdog을 사용한다.

방향 Cue는 모드 선택의 음성·방향 확인(Android)에서 별도로 사용자가 직접 시작한다. 일반 Guidance에는 신뢰할 실제 방향 출처가 없어 기본 TTS-only다. 별도 시험 화면의 성공과 일반 Guidance의 실제 이벤트 청취를 구분한다. TTS 자체의 HRTF 공간화·Head Tracking은 미검증이다.

## 5. BLE 값을 확보했을 때만

- 현재 예제 config/ble-local-demo.example.json은 entries=[]다. 실제 ID를 임의로 넣지 않는다.
- BLE 스캔 시작 → 수신 식별값 확인의 Android remoteId를 확인하고 비콘 제조사 앱/전원 ON/OFF와 대조한다. 광고 이름이나 가장 강한 RSSI만으로 버스를 확정하지 않는다.
- 예제를 저장소 밖에 복사하고 entries에 beaconId(MAC), busId(현재 Guidance 목표 ID와 정확히 일치), routeNo(선택 노선과 일치)를 입력한다. schemaVersion=1 / identifierField=android.remoteId는 유지한다.
- 기존 prepare_passenger_android.py에 --ble-demo-mapping <그 파일 경로>를 더해 일반 debug APK를 빌드한다. 새 APK는 새 해시로 고정·백업한 뒤 설치한다. 자격정보·관리자 토큰은 필요 없다.
- 이는 로컬 시연 매핑이다. 실제 운행 차량 등록으로 표현하지 않는다. 미등록/다른 차량/소실/재감지와 중복 TTS 억제를 확인한다. 실제 비콘이 없으면 이 구간은 미수행으로 둔다.

## 6. 복구 순서

| 증상 | 복구 |
|---|---|
| USB 단절 / Backend 연결 오류 | 카메라 중지 → 케이블/폰 디버깅 승인 확인 → Device 1회 실행 → Check → 새 카메라 시작. 반복 자동 재시도하지 않음 |
| 앱 화면/음성 이상 | STOP → 카메라 중지 → 필요 시 RestartApp. 앱 데이터는 유지됨 |
| Backend 재시작 | 앱 카메라 중지 → 기존 서버 창 Ctrl+C → Backend 재실행 → Check → 앱 로그아웃/로그인 → 새 Guidance 세션. 이전 Lease/Binding 재사용 금지 |
| 401/403 | 앱 로그아웃/로그인, 서버 프로젝트/모드 확인. 인증 우회·자동 Claims/IAM 변경 금지 |
| 모델 로딩 실패 | 오류 문구 기록, 고정 APK/모델 사용 여부 확인. 임의 모델 대체 금지 |
| 음성 중단 확인 실패 | STOP → 페이지 종료 → 필요 시 RestartApp. 겹쳐 재생하지 않음 |
| 최신 APK에서 기능 장애 | 확인본 APK 경로와 b0f8... 해시로 Install -r 후 기능 범위를 확인본 수준으로 줄임. 자동 uninstall/데이터 초기화 금지 |
| 8000 포트 사용 중 | Check로 기존 서버 확인. 알 수 없는 PID를 종료하지 않음 |

```powershell
& $demo -Action RestartApp
# 시연 종료 시, 기기가 연결된 상태에서만:
& $demo -Action StopApp
& $demo -Action Disconnect
# Backend 창에서 Ctrl+C
```

Disconnect는 이 도구가 새로 만든 reverse만 제거한다. 기존 reverse는 유지한다. 필요 시 사용자가 자신이 만든 기존 전달만 수동 제거한다. 시연 후 폰의 USB 디버깅/변경했던 Samsung 보안 설정을 원래 상태로 돌린다.

## 7. 백업과 보존

```powershell
& $demo -Action Backup -BackupDir 'C:/outside/mobi-demo-backup-새로운시각' -Apk $apk
python -B scripts/backup_demo_workspace.py --verify 'C:/outside/mobi-demo-backup-새로운시각'
```

실행 전 실제 새 폴더 경로로 바꾼다. 전체 Git worktree 밖만 허용하고 기존 폴더를 덮어쓰지 않는다. tracked + untracked(non-ignored) 소스, TFLite asset, staged/unstaged binary patch, Git 상태, 현재 HEAD 이력 bundle, 지정 APK와 SHA256 manifest를 저장·검증한다. 기존 소스를 reset/stash/checkout/delete하지 않는다.

.gitignore의 캐시/.venv/.env/자격 파일과 ADC는 복사하지 않는다. 외부 공개 google-services.json이나 확인본 APK도 포함하려면 Python 도구의 --artifact를 반복 지정한다. 서비스 계정/ADC/비밀번호를 추가하지 않는다. 이 PC의 인증 환경은 별도이며 다른 PC에서 자동 복구되지 않는다.

복구는 원본 작업 트리 대신 새 폴더에서 source 사본과 history.bundle을 사용한다. BACKUP_MANIFEST의 HEAD·파일 해시·deletedTrackedPaths를 확인하고 기존 변경 위에 패치를 무조건 덮어쓰지 않는다. 백업 검증은 파일 읽기만 수행한다.

## 8. 현재 판정과 연습 기록

| 기능 | 상태 |
|---|---|
| Android 로그인 / 카메라→TFLite→Backend→화면 | DONE: 이전 실기기 확인본 기준. 최신 APK는 재수락 필요 |
| 별도 Native TTS/Cue/STOP/Live Hold | DONE: 폰 스피커 사용자 확인. 좌우 정확도/Shokz는 미검증 |
| 일반 Guidance Audio | READY: 코드/빌드/Widget 검증, 실제 일반 이벤트 전체 문장 청취 대기 |
| BLE 매핑 경로 | READY: 로컬 시연 설정·파서 Fixture·빌드 완료 |
| 실제 BLE 목표 버스 식별 | BLOCKED: 실제 비콘 ID/차량 매핑·수신 증거 없음 |
| 실제 bus 양성 검출 / 성능 수치 / 중지·복구 반복 | READY: 실기기 수락 기록 필요 |
| 실제 TTS 공간화 / Head Tracking / 골전도 청취 | BLOCKED 또는 보류: 이번 완료 범위 아님 |

11/7 이후 기능 추가를 멈추고, 11/8까지 동일 APK·기기·서버로 5회 반복한다. 각 회차에 날짜/기종/OS/APK SHA256, 로그인, Preview, 서버 frameId 변화, STOP·재시작, TTS 전체 청취/출력 장치, 종료 후 잔여 처리, 복구 결과를 기록한다. 자동 callback PASS와 사용자 청취 PASS를 별도 칸에 기록한다. 미수행은 NOT_VERIFIED로 남긴다.


## 9. Camera DetectionResult → 화면 위치 Stereo Cue → TTS

일반 Passenger의 버스 카메라 화면에서만 사용하는 정보성 시연이다. 기존 NativeDirectionalCueOutput/FlutterSpeechEngine/SpeechPriorityCoordinator/SpatialVerificationEngine을 그대로 공유하며 별도 엔진이나 Coordinator를 만들지 않는다. 기존 SafetyInterpreter, 서버 Safety Event 및 Android Preview의 guidanceEligible=false는 변경하지 않는다. 기존 서버 관찰 음성의 source 허용 조건도 완화하지 않는다.

1. 최신 화면 음향 APK 설치 → 실제 로그인 → Guidance → 버스 카메라 시작 → 카메라 시작.
2. 모델과 Preview/실제 검출 결과 및 서버 수신 frameId가 갱신되는지 확인한다.
3. 기본 OFF인 카메라 화면 위치 Cue + 음성 시연 스위치를 직접 켠다. 새 유효 프레임만 평가하며 켜기 전 캐시 결과를 즉시 재생하지 않는다.
4. 승인된 입력의 버스를 검출 이미지 왼쪽/가운데/오른쪽에 놓고 확인한다. 실제 버스 사진을 촬영하면 사진 입력이라고 기록한다. 최고 confidence 객체 한 개만 선택한다. confidence 0.5 기준은 기존 Native 모델과 같다. 버스 정류장/문을 코드로 생성하지 않으며 모델에 실제로 있는 결과만 사용한다.
5. x + w/2가 1/3 미만이면 LEFT, 1/3~2/3이면 CENTER, 2/3 초과면 RIGHT다. bbox는 회전·미러 처리된 아래 결과 이미지의 정규화 좌표다. 정면 3D/몸/세계 좌표/거리/노선/승차 가능을 뜻하지 않는다. 이미 적용된 회전·미러를 두 번 계산하지 않는다.
6. 짧은 기존 Stereo Cue 완료/중단 확인 뒤 한국어 문장으로 실제 className을 읽는다. 음성 자체는 HRTF 공간화되지 않는다. 모델 추정이라는 정보성 시연이며 이동·회피·승차를 지시하지 않는다.
7. 최근 음향 요청 진단의 frameId, 프레임 시각, className, confidence, bbox, 중심 x, 화면 방향, 승인/완료 카운터를 기록한다. 모델/HTTP 처리는 음성 완료를 기다리지 않으므로 현재 서버의 최신 frameId와 최근 음향 요청 frameId가 서로 다를 수 있다.
8. 같은 classId+화면 영역의 연속 결과는 반복 안내하지 않는다. 객체 추적 ID는 구현하지 않는다. 다른 결과라도 기존 Vision 음성 정책과 같은 최소 8초 간격을 적용하고, 재생 중 들어온 프레임은 음향 큐에 쌓지 않는다. 좌/중/우를 바꿀 때 이전 문장 완료와 최소 간격을 기다린다.
9. Cue 중 화면 음향 STOP → 후속 TTS 없음, TTS 중 STOP → 중단, Cue/TTS 중 화면 음향 Live Hold → 이전 출력 중단, Hold 해제 → 과거 안내 자동 재생 없음을 각각 확인한다. 다른 기존 고우선순위 안내가 오면 Preview는 선점된다.
10. 카메라 중지/페이지 종료/로그아웃/세션 무효화 시 출력이 정리된다. 카메라 재시작 후 음향 스위치는 다시 직접 켠다. UI callback을 먼저 폐기하고 기존 owner의 오디오만 정리하며 부모 Guidance가 공유 엔진의 최종 소유자다.

카메라 프레임 admission은 기존 FramePump의 2초 신선도를 사용한다. 승인된 Cue→TTS 작업은 2초가 지났다는 이유만으로 중단하지 않으며 기존 30초 playback watchdog과 STOP/세션 취소를 따른다. 시작 전 만료는 다음 새 프레임을 기다린다. 중단 미확인은 기존 Coordinator quarantine을 유지하고 새 출력을 겹치지 않는다.

로컬 검증은 명시적 DetectionResult/FramePump/Native port/TTS Fixture다. 실제 Android 모델 검출→새 음향 경로 청취는 다음 폰 연결에서 별도로 확인한다. 기존 별도 오디오 화면의 스피커 성공을 DEVICE_VISION_AUDIO_PASS로 승격하지 않는다. Shokz·실제 방향 청취·실제 TTS 공간화·Head Tracking도 별도 미검증이다. 격리 offlinevision/localvision 시험 앱은 기본 음향 미연결을 유지한다.

이전 화면 음향 단계 APK SHA256: 37e38452536172782607eed6d9e29983909464fd3d516cffadfef1a5ef40b31d (이전 APK는 보존). 소스 종료 순서 최종 보완 후 관련 회귀 100 PASS, 전체 회귀는 464 PASS / 9 SKIP. 실제 새 경로 청취는 NOT_VERIFIED.


## 10. PC·Backend 없는 휴대폰 단독 시연 (LOCAL_DEMO)

일반 Passenger APK 첫 화면에서 **로컬 시연 · 카메라와 음향** → **로컬 카메라·음향 시작**을 누른다. Firebase 로그인, Guidance 서버 세션, Lease/Binding, ADB reverse는 이 경로에서 사용하지 않는다. 최초 APK 설치 이후 USB를 빼고 재실행할 수 있다. 로그인 설정 미완료·초기화 대기는 온라인 기능에만 적용한다.

1. USB를 분리한다. PC Backend가 꺼져 있어도 그대로 진행한다. 필요하면 휴대폰 Wi-Fi/모바일 데이터를 끄되 Bluetooth 이어폰 테스트 시 Bluetooth는 켠다.
2. 로컬 시연 입구에 **LOCAL_DEMO · Backend 미연결** 표시가 있는지 확인한다.
3. 로컬 카메라·음향 시작 → 모델 자동 준비 → 카메라 시작 → 카메라 권한 허용.
4. 실제 로컬 프레임과 객체명/confidence/bbox가 갱신되는지 확인한다. 서버 관찰/서버 수신 시각/ACK는 이 경로에 없다. 이때 통계는 기기 내부 결과다.
5. **카메라 화면 위치 Cue + 음성 시연**을 직접 켠다. 실제로 검출된 객체를 검출 이미지의 좌/중/우에 배치하고 Cue → 문장 전체를 듣는다. 방향은 카메라 이미지 기준이며 실제 3D 방향/거리/승차 판단이 아니다. 실제 검출한 클래스만 읽는다.
6. 같은 객체·같은 화면 영역 반복 안내 억제, 다른 결과의 최소 8초 간격, STOP, Live Hold 진입/해제, 카메라 중지·재시작을 확인한다. 재시작 시 음향 스위치는 다시 켠다.
7. 뒤로 가기/페이지 종료/앱 백그라운드에서 잔여 소리가 없는지 확인한다. 로컬 카메라 재진입은 새 로컬 수명 토큰을 사용한다. 이 토큰은 서버 세션이나 인증 자격이 아니다.
8. 휴대폰에 한국어 오프라인 TTS 음성이 설치되어 있어야 한다. 없으면 Android TTS 설정에서 먼저 준비한다. 네트워크 음성으로 몰래 대체하지 않으며, 초기화/중단 실패는 기존 오류·quarantine 정책을 따른다.
9. Shokz 등 Bluetooth 이어폰은 Android 시스템의 미디어 출력으로 연결한다. 앱은 기존 Native Cue/TTS 출력 경로를 사용하며 출력 장치 연결/청취 성공은 실기기에서 별도 확인한다.

로컬 시연의 BLE는 같은 기존 Android 스캐너를 사용한다. 등록 매핑이 없으면 미등록 상태로 스캔만 할 수 있다. 승인된 로컬 시연 매핑이 빌드에 포함된 경우 그 목록에서 목표를 직접 선택한다. 실제 운행 차량의 검증된 등록 정보로 표시하지 않는다. 카메라 진입 시 기존 BLE 스캔/안내를 정리하고, 두 기능은 하나의 기존 Coordinator를 사용한다. BLE는 방향 Cue·거리·승차 가능 여부를 만들지 않는다.

**온라인 서비스 · Firebase 로그인**은 기존 인증·세션·Lease·Backend 경로다. 서버 오류를 로컬 추론 성공/실패로 바꾸지 않으며, 서버가 없으면 온라인 연결 기능은 UNAVAILABLE이다. 온라인 중 오류가 나면 첫 화면으로 돌아와 로컬 시연을 명시적으로 선택한다. 자동으로 인증을 우회하거나 서버 관찰을 생성하지 않는다. 온라인 주소의 기존 127.0.0.1:8000은 변경하지 않았고 ADB reverse가 필요한 PC 개발 경로에만 사용된다.

현재 판정은 STANDALONE_APP_READY 목표의 코드/빌드 검증이다. USB 제거 후 실제 카메라·TFLite·전체 문장·Bluetooth 청취를 확인하기 전에는 DEVICE_STANDALONE_PASS가 아니다. guidanceEligible=false, Safety Event/위험 Guidance/출입문·거리·노선 추정 없음.

휴대폰 단독 시연 최신 일반 Debug APK: C:/Users/lucid/.codex/visualizations/2026/10/05/01a10b2b-8699-7732-bb48-e2edbcfeaef6/standalone-passenger-20261103/mobi-passenger-standalone-debug.apk
SHA256: 79049294311fd37c800cfa086dff0203c5bade9403f32c43a01fe5f1870e4d0c
이전 Vision 화면 음향 APK 37e384...는 이전 확인본으로 보존하며 신규 단독 실행의 실기기 수락을 대체하지 않는다.

최종 코드 검증: Passenger 467 PASS / 9 SKIP, Flutter analyze PASS, 일반 Android debug APK 빌드 PASS. 실제 단독 청취 NOT_VERIFIED.
