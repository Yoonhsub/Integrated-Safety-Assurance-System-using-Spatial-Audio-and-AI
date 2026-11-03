# Passenger 앱의 본인 카메라 관찰

일반 `lib/main.dart` → 로그인 → Guidance 세션 → **버스 카메라 시작** → **카메라 시작**.
별도 시험 APK, 관리자 토큰, 생산자 자격 JSON, PC 수동 Binding이 필요하지 않다.
기존 승인 TFLite 모델을 앱 자산에 포함하고 기존 SHA256 검사 후 사용한다.

## 서버 설정

기존 FastAPI를 단일 Worker로 실행한다. 일반 서비스 인증·저장소 설정을 그대로 사용하고
`MOBI_PASSENGER_CAMERA_PREVIEW=1`로 본인 카메라 Preview 기능을 활성화한다.
이 값은 Firebase 인증을 우회하거나 Fake 인증을 활성화하지 않는다.
운영 연결은 기존 `MOBI_API_BASE_URL`과 HTTPS 구성을 사용한다.
이 변경에서 Firebase 접속이나 운영 서버 배포는 수행하지 않았다.

## 연결

- 기존 Start Ticket / Lease 협상은 사용자가 카메라를 시작할 때 수행한다.
- 서버가 인증된 Passenger UID와 소유 Guidance 세션에서 카메라 식별자를 결정한다.
- `POST /ai-vision/v2/sessions/{sessionId}/phone-camera`가 본인 세션을 연결한다.
- 같은 경로의 `/events`가 기존 DetectionResult / Android source 검증과 저장·조회 경로를 재사용한다.
- `DELETE .../phone-camera/{bindingId}`는 해당 카메라 연결과 표시 결과를 제거한다.
- 기존 외부 생산자 `/events` 및 관리자 등록·Binding 권한은 그대로 유지한다.
- 카메라 화면을 여는 동안 부모 Guidance 화면의 중복 Vision 조회를 중지한다.
- 카메라 연결이 준비되기 전 실패해도 기존 일반 Guidance 요청에는 Lease를 강요하지 않는다.

## 출력 범위

기존 Camera Preview, 객체명·confidence·bbox·프레임 시각·추론 지연을 표시한다.
검출 JSON만 전송하며 영상은 업로드하지 않는다. `guidanceEligible=false`이며
Safety Event, 위험 Guidance, Vision 기반 자동 음성은 생성하지 않는다.
모델 메타데이터는 클라이언트 주장이고 촬영/모델 실행에 대한 서버 증명은 아니다.
출입문 방향·거리·승차 가능 여부는 생성하지 않는다.

## 실행 증거의 한계

일반 Android APK 빌드와 로컬 Fake 인증/메모리 저장소의 HTTP 흐름은 확인할 수 있지만,
연결되지 않은 Android 기기 카메라, 네이티브 TFLite 실행, 실제 Firebase 저장은 검증되지 않았다.
Lease/Binding 권위는 기존 단일 프로세스 메모리 기반이며 서버 재시작·다중 Worker 복구는 이번 범위가 아니다.


## Android 설치 파일 준비

일반 앱의 Android 로그인에는 Firebase에 등록된 `com.example.mobi_passenger_app`의
**Android app ID**가 필요하다. Web app ID로 대체할 수 없다.
앱 설정은 공개 클라이언트 설정이며 서비스 계정 키/관리자 토큰/생산자 비밀은 넣지 않는다.
Android에서는 Web authDomain이 없어도 초기화할 수 있다.

기존 `google-services.json`으로 설정 검사 및 일반 debug APK 빌드:

```powershell
python scripts/prepare_passenger_android.py --google-services C:/outside/google-services.json --backend-url http://127.0.0.1:8000
python scripts/prepare_passenger_android.py --google-services C:/outside/google-services.json --backend-url http://127.0.0.1:8000 --flutter "C:/Flutter SDK/flutter/bin/flutter.bat" --build
```

또는 `apps/passenger_app/config/android-usb.example.json`을 저장소 밖에 복사하여
Android 공개 설정을 채운 후 `--settings C:/outside/passenger-android.json --build`를 사용한다.
템플릿 그대로는 설정 검사에 실패한다. 준비되지 않은 설정으로 로그인 가능 APK라고 보고하지 않는다.
도구는 `lib/main.dart`만 빌드하고 개발용 Fake 인증 define은 허용하지 않는다.
빌드만으로 Firebase Auth/RTDB에 접속하지 않는다. 실제 로그인/서버 실행은 별도 접속 승인 후 수행한다.

## USB 기기 연결 후 실행

현재 기기가 없으면 `DEVICE_NOT_CONNECTED`로 남긴다. 기기 연결 후 승인된 PC 서버를
loopback `127.0.0.1:8000`에서 실행하고 다음을 수행한다. APK 설치 명령은 로그인하지 않는다.

```powershell
adb devices -l
adb reverse tcp:8000 tcp:8000
adb install -r apps/passenger_app/build/app/outputs/flutter-apk/app-debug.apk
```

앱을 직접 열어 로그인 → **실시간 API 모드** → 안내 이름 설정(최초 1회) → Guidance
→ **버스 카메라 시작** → **카메라 시작** → 카메라 권한 허용 순서로 사용한다.
모델 파일/관리자 자격/Binding JSON을 사용자가 선택할 필요는 없다.
앱이 로그인을 마쳤어도 Backend의 정상 Firebase 검증·저장소 및 `mobi_role=passenger`가
구성돼 있어야 Guidance 세션과 카메라 연결이 성공한다.
USB reverse 없이 휴대폰의 `127.0.0.1` 주소로 PC에 접속할 수는 없다.

서버 오류 시 현재 화면에서 연결 오류를 확인하고 서버 복구 후 다시 카메라 시작을 누른다.
추론/전송 중 화면을 나가거나 앱이 백그라운드로 이동하면 카메라와 전송은 중단된다.
테스트 종료 후 이 작업에서 추가한 reverse만 제거한다:

```powershell
adb shell am force-stop com.example.mobi_passenger_app
adb reverse --remove tcp:8000
```

## USB 없는 연결과 배포 구분

USB 없이 연결할 때는 외부에서 접근 가능한 기존 Backend의 유효한 인증서가 있는
HTTPS origin을 `MOBI_API_BASE_URL`에 넣어 새로 빌드한다.
Wi-Fi 사설 IP에 대한 광범위한 HTTP 허용이나 임의 인증서 신뢰는 추가하지 않았다.
일반 debug Manifest만 `127.0.0.1` HTTP를 허용한다. Release에 이 예외는 포함되지 않는다.
Release의 서버 주소가 비어 있거나 HTTP/loopback이면 앱은 설정 안내를 표시한다.
Release 서명/운영 배포는 이번 준비 범위에 포함되지 않는다.
기존 offlinevision/localbackend/localaudio/localvision 진입점과 격리 가드는 변경하지 않는다.
