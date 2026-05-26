# Android Studio 설치 및 Flutter Android 실행 가이드

## 1. 목적

본 문서는 Flutter Web 중심으로 개발된 `mobi-smart-transport-ai` 프로젝트를 Android 에뮬레이터 환경에서 실행하기 위한 절차를 정리한 문서이다.

대상 앱은 다음과 같다.

- `apps/passenger_app`
- `apps/driver_app`

본 문서는 Git과 Flutter SDK가 이미 설치되어 있다는 전제에서 작성하였다.

---

## 2. 사전 준비 상태

이미 준비되어 있어야 하는 항목은 다음과 같다.

- Git 설치 완료
- Flutter SDK 설치 완료
- Flutter 환경 변수 설정 완료
- VS Code 설치 완료
- VS Code Flutter / Dart Extension 설치 완료
- 프로젝트 clone 완료 또는 clone 예정

확인 명령어는 다음과 같다.

```powershell
git --version
```

```powershell
flutter --version
```

```powershell
flutter doctor
```

---

## 3. Android Studio 설치

Android Studio 공식 다운로드 페이지에서 설치 파일을 다운로드한다.

설치 파일을 실행한 뒤 기본 옵션으로 설치한다.

설치가 끝나면 Android Studio를 한 번 실행한다.

처음 실행 시 Setup Wizard가 나오면 다음 순서로 진행한다.

```text
Standard
→ Next
→ 설치 항목 확인
→ Finish
```

이 과정에서 Android SDK 기본 구성요소가 설치된다.

---

## 4. Android SDK 구성 확인

Android Studio 첫 화면에서 다음 메뉴로 이동한다.

```text
More Actions
→ SDK Manager
```

프로젝트가 열린 상태라면 다음 메뉴로 이동한다.

```text
Tools
→ SDK Manager
```

### 4.1 SDK Platforms 탭

다음 항목을 설치한다.

```text
Android API 36
```

이미 설치되어 있으면 그대로 둔다. 설치되어 있지 않으면 체크 후 `Apply`를 누른다.

### 4.2 SDK Tools 탭

다음 항목이 설치되어 있는지 확인한다.

```text
Android SDK Build-Tools
Android SDK Command-line Tools
Android Emulator
Android SDK Platform-Tools
CMake
NDK (Side by side)
```

설치되어 있지 않은 항목은 체크 후 `Apply`를 눌러 설치한다.

특히 `Android SDK Command-line Tools`가 없으면 이후 `flutter doctor`에서 오류가 발생할 수 있다.

---

## 5. Flutter에서 Android SDK 인식 확인

PowerShell 또는 VS Code 터미널에서 다음 명령어를 실행한다.

```powershell
flutter doctor
```

Android SDK를 찾지 못한다면 Android SDK 경로를 직접 지정한다.

Windows 기준 Android SDK 기본 경로는 보통 다음과 같다.

```text
C:\Users\사용자이름\AppData\Local\Android\Sdk
```

예시 명령어는 다음과 같다.

```powershell
flutter config --android-sdk "C:\Users\사용자이름\AppData\Local\Android\Sdk"
```

그 다음 Android 라이선스에 동의한다.

```powershell
flutter doctor --android-licenses
```

질문이 나오면 모두 `y`를 입력한다.

다시 확인한다.

```powershell
flutter doctor
```

정상 상태는 다음과 같다.

```text
No issues found!
```

---

## 6. Android 에뮬레이터 생성

Android Studio에서 다음 메뉴로 이동한다.

```text
More Actions
→ Virtual Device Manager
```

프로젝트가 열린 상태라면 다음 메뉴로 이동한다.

```text
Tools
→ Device Manager
```

다음 순서로 에뮬레이터를 생성한다.

```text
Create Device
→ Phone
→ Pixel 6 또는 Pixel 7 선택
→ Next
→ API 35 또는 API 36 system image 선택
→ Download
→ Next
→ Finish
```

생성 후 Device Manager에서 오른쪽의 `▶` 버튼을 눌러 에뮬레이터를 실행한다.

에뮬레이터 홈 화면까지 완전히 켜진 뒤 터미널에서 다음 명령어를 실행한다.

```powershell
flutter devices
```

정상적으로 인식되면 다음과 비슷한 Android 기기가 표시된다.

```text
emulator-5554
```

---

## 7. VS Code에서 프로젝트 열기

프로젝트 루트로 이동한다.

예시 경로는 다음과 같다.

```powershell
cd C:\capstone\Integrated-Safety-Assurance-System-using-Spatial-Audio-and-AI\mobi-smart-transport-ai
```

VS Code로 프로젝트를 연다.

```powershell
code .
```

---

# 8. passenger_app Android 실행 절차

## 8.1 passenger_app으로 이동

프로젝트 루트 기준으로 다음 명령어를 실행한다.

```powershell
cd apps/passenger_app
```

## 8.2 Android 폴더 존재 여부 확인

먼저 `android` 폴더가 있는지 확인한다.

```powershell
dir android
```

정상이라면 다음과 같은 항목들이 보여야 한다.

```text
app
gradle
build.gradle 또는 build.gradle.kts
settings.gradle 또는 settings.gradle.kts
```

더 정확히 `AndroidManifest.xml` 존재 여부를 확인한다.

```powershell
dir android\app\src\main
```

다음 파일이 있어야 한다.

```text
AndroidManifest.xml
```

## 8.3 Android 폴더가 없을 경우 생성

`dir android` 명령어 실행 시 폴더가 없거나, `AndroidManifest.xml`이 없다면 다음 명령어를 실행한다.

```powershell
flutter create --platforms=android .
```

이 명령어는 새 프로젝트를 만드는 것이 아니라, 현재 Flutter 앱에 Android 실행용 플랫폼 파일을 추가하는 명령이다.

생성 후 다시 확인한다.

```powershell
dir android
```

```powershell
dir android\app\src\main
```

`AndroidManifest.xml`이 보이면 정상이다.

## 8.4 passenger_app 의존성 설치 및 분석

```powershell
flutter pub get
```

```powershell
flutter analyze
```

정상 결과는 다음과 같다.

```text
No issues found!
```

## 8.5 passenger_app 실행

에뮬레이터가 켜져 있는지 다시 확인한다.

```powershell
flutter devices
```

에뮬레이터 ID가 `emulator-5554`라면 다음 명령어로 실행한다.

```powershell
flutter run -d emulator-5554 --dart-define=MOBI_API_BASE_URL=http://10.0.2.2:8000
```

에뮬레이터에서는 PC의 `localhost:8000`에 접근할 때 보통 다음 주소를 사용한다.

```text
http://10.0.2.2:8000
```

기기 ID가 다르면 `flutter devices`에 나온 ID로 바꿔서 실행한다.

```powershell
flutter run -d 실제기기ID --dart-define=MOBI_API_BASE_URL=http://10.0.2.2:8000
```

---

# 9. driver_app Android 실행 절차

## 9.1 driver_app으로 이동

현재 `apps/passenger_app`에 있다면 다음 명령어를 실행한다.

```powershell
cd ..\driver_app
```

프로젝트 루트에 있다면 다음 명령어를 실행한다.

```powershell
cd apps/driver_app
```

## 9.2 Android 폴더 존재 여부 확인

```powershell
dir android
```

`AndroidManifest.xml` 존재 여부를 확인한다.

```powershell
dir android\app\src\main
```

다음 파일이 있어야 한다.

```text
AndroidManifest.xml
```

## 9.3 Android 폴더가 없을 경우 생성

`android` 폴더나 `AndroidManifest.xml`이 없다면 다음 명령어를 실행한다.

```powershell
flutter create --platforms=android .
```

다시 확인한다.

```powershell
dir android
```

```powershell
dir android\app\src\main
```

## 9.4 driver_app 의존성 설치 및 분석

```powershell
flutter pub get
```

```powershell
flutter analyze
```

## 9.5 driver_app 실행

에뮬레이터 ID를 확인한다.

```powershell
flutter devices
```

에뮬레이터 ID가 `emulator-5554`라면 다음 명령어로 실행한다.

```powershell
flutter run -d emulator-5554 --dart-define=MOBI_API_BASE_URL=http://10.0.2.2:8000
```

---

# 10. 실행 후 확인 항목

## 10.1 passenger_app 확인 항목

다음 화면 요소가 표시되는지 확인한다.

- MOBI 승객 앱 실행 여부
- 백엔드 연결 상태 카드
- 음성으로 목적지 입력 버튼
- 현재 상태 음성 안내 버튼
- 안전 상태 카드
- 버스 도착 정보 카드
- 탑승 요청 상태 카드
- 탑승 요청하기 버튼
- 상태 조회 버튼
- 백엔드 미실행 시 연결 실패 fallback 표시

백엔드 서버가 실행 중이지 않다면 연결 실패 fallback이 표시되는 것이 정상이다.

## 10.2 driver_app 확인 항목

다음 화면 요소가 표시되는지 확인한다.

- MOBI 기사 앱 실행 여부
- 백엔드 연결 상태 카드
- 운행 상태 카드
- 탑승 요청 목록 카드
- 요청 목록 새로고침 버튼
- 요청 목록 조회 실패 fallback 표시
- 요청 수락 상태 변경 구조

백엔드 서버가 실행 중이지 않거나 요청 데이터가 없으면 요청 목록 조회 실패 또는 요청 없음 fallback이 표시될 수 있다.

---

# 11. Git 상태 확인

Android 플랫폼 파일을 새로 만들었다면 파일이 많이 생길 수 있다.

프로젝트 루트로 돌아가서 확인한다.

```powershell
cd ..\..
```

```powershell
git status
```

정상적으로 추가될 수 있는 범위는 다음과 같다.

```text
apps/passenger_app/android/**
apps/driver_app/android/**
```

주의해야 할 범위는 다음과 같다.

```text
backend/**
services/public_data/**
packages/shared_contracts/**
packages/mobile_sensors/**
infrastructure/**
ai_vision/**
```

위 범위의 파일이 의도치 않게 변경되었다면 커밋하지 않는 것이 좋다.

---

# 12. 자주 발생하는 문제와 해결

## 12.1 `No supported devices found with name or id matching 'android'`

원인:

- Android 에뮬레이터가 실행되지 않았거나 Flutter가 인식하지 못한 상태이다.

해결:

```powershell
flutter devices
```

Android 기기가 보이지 않으면 Android Studio의 Device Manager에서 에뮬레이터를 실행한다.

## 12.2 `AndroidManifest.xml`을 찾을 수 없다는 오류

원인:

- 앱 폴더에 `android/` 플랫폼 폴더가 없다.
- 또는 `android/app/src/main/AndroidManifest.xml`이 없다.

해결:

```powershell
flutter create --platforms=android .
```

그 다음 다시 확인한다.

```powershell
dir android\app\src\main
```

## 12.3 `cmdline-tools component is missing`

원인:

- Android SDK Command-line Tools가 설치되지 않았다.

해결:

```text
Android Studio
→ SDK Manager
→ SDK Tools
→ Android SDK Command-line Tools 체크
→ Apply
```

그 다음:

```powershell
flutter doctor
```

## 12.4 Android license 오류

해결:

```powershell
flutter doctor --android-licenses
```

나오는 질문에 모두 `y`를 입력한다.

## 12.5 에뮬레이터 빌드가 오래 걸리는 경우

처음 Android 빌드는 오래 걸릴 수 있다.

다만 10분 이상 멈춘 것처럼 보이면 다음 순서로 정리한다.

```powershell
Ctrl + C
```

```powershell
flutter clean
```

```powershell
flutter pub get
```

```powershell
flutter run -d emulator-5554 --dart-define=MOBI_API_BASE_URL=http://10.0.2.2:8000
```

## 12.6 NDK 관련 오류

예시 오류:

```text
NDK did not have a source.properties file
```

원인:

- Android NDK 설치가 깨졌거나 불완전하게 설치된 상태이다.

해결 방향:

- Android Studio의 SDK Manager에서 `NDK (Side by side)`를 재설치한다.
- 또는 깨진 NDK 폴더를 삭제한 뒤 다시 설치한다.

## 12.7 Vanguard 등 안티치트 프로그램과 에뮬레이터 충돌

일부 안티치트 프로그램은 Android Emulator와 충돌할 수 있다.

해결 방향:

- 안티치트 프로그램을 종료한 뒤 재부팅
- 에뮬레이터 대신 실제 Android 기기로 테스트
- 해당 문제는 앱 코드 문제가 아니라 로컬 PC 환경 문제로 분리

---

# 13. 전체 순서 요약

```text
1. Android Studio 설치
2. Android Studio 첫 실행 및 SDK 설치
3. SDK Manager에서 API 36, Command-line Tools, Emulator, Platform-Tools, NDK 확인
4. flutter doctor 확인
5. flutter doctor --android-licenses 실행
6. Android Studio에서 에뮬레이터 생성
7. 에뮬레이터 실행
8. flutter devices로 emulator 확인
9. VS Code에서 mobi-smart-transport-ai 열기
10. apps/passenger_app으로 이동
11. dir android 확인
12. dir android\app\src\main 확인
13. AndroidManifest.xml 없으면 flutter create --platforms=android .
14. flutter pub get
15. flutter analyze
16. flutter run -d emulator-5554 --dart-define=MOBI_API_BASE_URL=http://10.0.2.2:8000
17. apps/driver_app도 동일하게 진행
18. git status로 변경 범위 확인
```

---

# 14. 담당 범위 관련 주의 사항

Android 에뮬레이터 생성과 passenger_app / driver_app Android 실행 검증은 앱 실행 환경 검증에 해당한다.

윤현섭 담당 범위 안에서 확인 가능한 범위는 다음과 같다.

```text
apps/passenger_app/**
apps/driver_app/**
```

다음 범위는 임의로 수정하지 않는다.

```text
backend/**
services/public_data/**
packages/shared_contracts/**
packages/mobile_sensors/**
infrastructure/**
ai_vision/**
```

특히 BLE/RSSI, geofence, FCM, native sensor 연동은 담당 모듈 계약 확정 후 진행하는 것이 안전하다.

따라서 Android 에뮬레이터 검증 범위는 다음으로 제한하는 것이 좋다.

- 앱 실행 여부
- UI 표시 여부
- 버튼 및 상태 카드 표시 여부
- fallback 렌더링 여부
- STT/TTS 버튼 및 기본 동작 확인
- 범위 밖 모듈 수정 없음 확인
