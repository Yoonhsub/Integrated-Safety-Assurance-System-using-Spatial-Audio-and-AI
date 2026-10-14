# Android 로컬 카메라·TFLite 관찰

## 지원 범위
Android API26 이상을 우선 지원한다. iOS/웹/Windows에는 지원 불가 안내만 표시한다. Windows에서는 iOS 빌드/실기기 검증을 수행하지 않는다.
이 모듈은 서버 Observation API, Producer 인증, 안전 판단, BLE, TTS와 연결되지 않는다. 앱 내부 관찰이며 Vision만으로 목표 버스 또는 승차 가능 여부를 판단하지 않는다.

## 모델 준비
`feature/add-tflite-baseline`의 실제 LFS 모델 `yolo11n_bus_door_v1_float32.tflite`를 휴대폰에 개인적으로 준비한다. 모델은 이 브랜치나 APK assets에 포함하지 않는다. 통합 브랜치에서 git lfs pull만 실행해도 모델이 생기는 것은 아니다.
허용 SHA256: `7178a76b3abaa83bfac0ad9c5b1ea40627560d6aa0e05587b335950a1bffaa85`.
앱의 파일 선택기로 파일을 선택하면 크기 및 SHA를 검사한다. 잘못된 파일/LFS pointer는 native runtime 로딩 전에 거부한다. 선택한 파일은 메모리에서 사용하며 원본을 변경하지 않는다. 사용 조건·재배포 권한은 별도로 확인해야 한다.

입력은 float32 `[1,640,640,3]`, RGB/255, letterbox114이다. 출력은 float32 `[1,6,8400]`, 채널0~3 정규화cx/cy/w/h, 채널4 bus(class0), 채널5 bus_door(class1)이다. confidence0.5, class별 NMS IoU0.45를 적용한다. 장애물과 bus_stop은 이 모델의 클래스가 아니다.

## 실행
현재 Android applicationId는 생성된 개발용 `com.example.mobi_passenger_app`이다. 배포용 등록·서명 및 Firebase Android 앱 설정은 별도 작업이다.
Firebase 로그인/토큰/보호 API를 포함하지 않는 명시적 로컬 시험 진입점:

```powershell
Set-Location '<통합 worktree>\mobi-smart-transport-ai\apps\passenger_app'
flutter devices
flutter run -d <Android-device-id> -t lib/local_vision_main.dart
# 실제 기기가 없을 때 빌드 확인만
flutter build apk --debug -t lib/local_vision_main.dart
```

앱에서 `TFLite 모델 선택` → `카메라 시작` → 권한 허용 순으로 진행한다. 정지/재시작, 화면 나가기, 백그라운드 전환을 시험한다. 기본은 후면 카메라이며 전면 선택은 정지 상태에서만 가능하다.
정상 승객 앱에는 로그인 후 모드 선택 화면의 `휴대폰 로컬 카메라 관찰` 버튼과 인증된 `/local-vision` 경로가 추가된다. 로그아웃하면 AuthGate가 화면을 폐기해 카메라를 중단한다. 로컬 카메라 시험용 main은 보호 API를 호출할 수 있는 우회 로그인 경로가 아니다.
현 Firebase 구조는 웹 중심 설정으로 개발됐다. 정상 Android 승객 앱 로그인은 실제 Android Firebase appId/config로 별도 검증해야 한다. 아직 확인되지 않은 설정을 임의 등록하거나 Producer 권한을 승객에게 부여하지 않는다.

## 프레임·좌표·수명
YUV420 row/pixel stride, 단일 plane NV21, BGRA8888을 변환한다. 알 수 없는 plane 형식은 오류 처리한다. 센서 방향과 기기 방향으로 RGB를 회전하고 전면 이미지는 명시적으로 미러링한다. 모델과 화면은 동일하게 보정한 프레임을 사용한다. bbox는 그 이미지의 정규화 좌표로 표시한다. 실제 기기의 방향/앞뒤 카메라 정확성은 실기기에서 확인해야 한다.
Python 참조의 tie-to-even 정수 반올림과 맞춘 letterbox를 사용한다. 화면은 추론에 사용한 프레임 JPEG에 박스를 그리며 촬영/영상 파일을 저장하지 않는다.
한 worker isolate가 전처리/추론/후처리를 담당한다. 추론 1개와 대체 가능한 최신 대기 프레임 1개로 제한한다. 오래된 대기/완료 결과는 폐기하며 입력이 멈추면 관찰이 만료된다. 현재2초 TTL은 개발용 값이며 안전 인증된 기준이 아니다.
시각은 호스트의 카메라 callback 수신 시각과 monotonic clock이다. 센서 노출 시각이나 실제 거리·접근 속도를 보장하지 않는다. 모델 초기화/warm-up 후에 카메라 스트림을 시작한다.
종료 시 새 입력과 관찰을 즉시 차단하고 카메라를 해제한다. 실행 중 native invoke는 강제 종료하지 않고 완료 후 interpreter/options를 해제한다. 영상 plane은 결과에 재첨부하지 않는다.

## 검증과 남은 작업
영상 변환·좌표·class별NMS·최신 프레임·만료·종료 경합은 fixture 단위 테스트 대상이다. 실제 카메라 권한/방향/검출/FPS/발열/메모리 안정성은 물리 기기에서 별도로 확인해야 한다. 에뮬레이터 가상 카메라와 PC Python 모델 결과를 실제 휴대폰 결과로 보고하지 않는다.
SDK 플랫폼34/35/36은 기존 플러그인들의 compileSdk에 필요할 수 있다. 새로운 SDK 약관은 사용자가 `flutter doctor --android-licenses`에서 직접 확인해야 한다. Gradle은 SDK 자동 다운로드를 비활성화했다.

향후 서버 전달 시 모바일 Observation을 기존 서버 인증 Observation과 구분하고, 승객 UID/기기 Producer identity/카메라/안내 세션을 서버에서 검증하는 권한 모델을 설계한다. 승객 토큰에 Producer 역할을 임의 부여하거나 관리자 키/공유 Producer 암호를 앱에 넣지 않는다. 불변 eventId/본문 재시도, token 갱신, frame epoch/순서/만료, 로그아웃 취소 정책은 모바일용으로 별도 구현한다.
