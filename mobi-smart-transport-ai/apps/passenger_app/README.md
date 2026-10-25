# MOBI Passenger App

윤현섭 담당 Flutter 사용자 앱 영역입니다.

## Web demo 실행 방법

iPhone 빌드가 병목이므로 우선 Flutter Web 으로 데모를 확인한다. 데모 데이터 쓰기는
Flutter 클라이언트가 아니라 FastAPI 백엔드의 Firebase Admin SDK 가 수행한다.

### 1. 백엔드 실행

```bash
cd backend/api
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

### 2. 상태 확인

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/firebase/status
```

### 3. Firebase 데모 초기화 (백엔드 Admin SDK)

```bash
curl -X POST http://127.0.0.1:8000/firebase/initialize \
  -H "Content-Type: application/json" \
  -d '{"reset": false}'
```

### 4. Flutter Web 실행

```bash
cd apps/passenger_app
flutter pub get
flutter run -d chrome \
  --web-hostname localhost \
  --web-port 5173 \
  --dart-define MOBI_API_BASE_URL=http://127.0.0.1:8000
```

### 5. 앱에서 확인

- 홈 화면의 **Firebase 데모 DB 초기화** 버튼을 누른다(백엔드 카드 바로 아래의 "Firebase 데모 DB" 카드).
  - 실제 Firebase 연결이면 `Firebase 데모 DB 초기화 완료` SnackBar 와 seed 경로 Dialog 가 표시된다.
  - 서비스 계정이 없으면 `서비스 계정이 없어 mock DB에 초기화됨` 으로 표시된다.
  - `기존 데모 데이터 덮어쓰기(reset)` 스위치를 켜면 demo 경로만 삭제 후 재 seed 한다.
- `V3 버스 탑승 보조 열기` 로 V3 화면을 연다.
- mock geofence/beacon 버튼으로 시나리오를 확인한다.

### 참고 / 주의

- 서비스 계정 json 이 없으면 백엔드는 자동으로 mock DB 로 동작한다.
- 실제 Firebase RTDB 에 쓰려면 `backend/api/secrets/firebase-service-account.json` 이 필요하다.
- `FIREBASE_DATABASE_URL` 이 실제 콘솔 URL 과 다르면 루트 `.env` 를 수정한다.
  연결 실패 시 `/firebase/status` 의 `probe.message` 에 "Realtime Database URL 확인 필요" 안내가 표시된다.
- 데모 개발버전에서는 `.env` 를 로컬에 포함하지만 **공개 저장소에는 올리지 않는다**(.gitignore 처리됨).
- 클라이언트 측 FlutterFire 구성은 `lib/firebase_options.dart`(web) 가 생성되어 있으며,
  `lib/src/firebase/firebase_bootstrap.dart` 에서 `Firebase.initializeApp` 을 안전하게 호출한다.
  이 파일이 없는 환경에서도 데모는 백엔드 endpoint 만으로 동작한다.
  iOS 용 구성이 필요하면 `flutterfire configure --platforms=ios` 를 추가 실행한다
  (현재 환경에서는 ruby `xcodeproj` gem 부재로 iOS 등록 단계가 실패하여 web 만 구성됨).


## 목적

`passenger_app`은 시각장애인/노약자/일반 승객이 버스 정류장과 탑승 요청 기능을 이용하는 사용자 앱 스캐폴딩입니다.

## 4월 구현 범위

- 사용자 앱 기본 화면과 라우팅 골격
- 접근성 Semantics 라벨
- 목적지 입력을 위한 STT/TTS 또는 음성 안내 UI 구조
- 지오펜싱 안전 상태, 버스 도착 정보, 탑승 요청 결과 렌더링
- 백엔드 API client skeleton 정리

## 사용자 앱 API 연동 대상

- `POST /geofence/check`
- `GET /bus-info/stops/{stopId}/arrivals`
- `POST /ride-requests`
- `GET /ride-requests/{requestId}`

현재 `backend_api_client.dart`는 shared API 계약 기준으로 실제 HTTP 요청을 시도한다. `POST /ride-requests` live mode payload는 화면 상태의 passenger/user id, 선택된 stop id, 선택된 route id, bus number, 선택적 target driver id를 조합해 생성하며, 클라이언트 내부 고정 demo JSON을 전송하지 않는다.

## 경계

- 백엔드 로직은 `backend/api`에서 구현한다.
- 공공데이터 API 직접 호출은 하지 않고 백엔드 또는 표준 응답을 통해 받는다.
- BLE/RSSI 로직은 `packages/mobile_sensors`에서 구현한다.
- 기사 앱 UI와 기사 전용 탑승 요청 처리 화면은 `apps/driver_app`에서 다룬다.

## mobile_sensors 의존성 정책

`passenger_app`은 향후 BLE/RSSI/방향 센서 기능의 실제 소비자이므로 `mobi_mobile_sensors` path dependency를 유지한다. 단, 4월 범위에서는 BLE/RSSI 실연동 UI가 강한 선행 의존성이 아니며, 윤현섭 에이전트는 placeholder/mock 기반 UI shell을 독립 구현할 수 있다. 실제 센서 연동 확정은 안준환 `packages/mobile_sensors` 산출물 검토 후 진행한다.

## V3 음성 기반 버스 탑승 보조 화면

V3 화면은 홈 화면의 `V3 버스 탑승 보조 열기` 버튼 또는 `/v3-guidance` route로 접근한다.

주요 연결 endpoint는 다음과 같다.

```txt
GET  /health
POST /guidance/session
GET  /guidance/state?sessionId=demo-session
POST /guidance/reset
POST /agent/converse
POST /agent/tts
GET  /bus/route-recommend?destination=사창사거리
GET  /bus/arrivals?stopId=mock-stop-001&routeNo=502
POST /mock/geofence
POST /mock/beacons
POST /mock/bus-event
GET  /beacon/decision
```

API base URL은 Dart define으로 지정한다.

```bash
flutter run --dart-define MOBI_API_BASE_URL=http://127.0.0.1:8000
```

Android emulator에서 로컬 백엔드에 붙일 때는 host loopback 대신 `10.0.2.2`를 사용한다.

```bash
flutter run --dart-define MOBI_API_BASE_URL=http://10.0.2.2:8000
```

Gemini API key가 없어도 V3 화면은 백엔드 rule fallback endpoint를 호출한다. 안전 판단, 지오펜싱 경고, 잘못된 버스 접근 경고는 Flutter가 직접 추측하지 않고 백엔드 rule engine 응답의 `cue`와 `state`를 따른다.

헤드트래킹 debug 표시는 optional이다. 센서가 없어도 앱이 죽지 않도록 기본값은 `optional · 센서 미연결`이며, 현재 V3 화면에서는 yaw/pitch/roll mock 표시만 지원한다. 이 값은 탑승 가능 판단을 대체하지 않는다.

V3 백엔드와 앱의 계약은 `docs/rw/V3_API_CONTRACTS.md`를 기준으로 맞춘다. 전체 시연 순서는 `docs/rw/V3_DEMO_SCRIPT.md`와 `scripts/smoke_v3_guidance.py`를 따른다.

최초 실행에서는 사용자가 에이전트 이름을 지정한다. 저장한 이름은 이후 호출어로
사용된다. 일반 대화는 Gemini Flash, 위치 기반 경로 계산은 Gemini Pro와 Google Maps
grounding, 음성 응답은 `Sulafat` voice를 우선 사용한다.

경로 계산 중에는 화면에 `생각 중...` 오버레이를 표시한다. 결과 화면은 Google Maps
위치 증빙, 실제 청주시 공공 API 정류소 증빙, 별도 도착정보 출처 카드를 구분해서
표시한다. 도착정보가 mock이면 `시연 데이터 · 실제 공공 API 아님`으로 표시한다.


## 로컬 Android 하드웨어 버스 안내 (2026-10-25)

실제 Passenger 앱의 첫 모드 선택 화면에서 **실기기 연동확인**를 엽니다. 이 화면은 별도 임시 앱이 아니며, 서버에 연결하지 않고 실제 BLE/WT901/골전도 입력·출력을 사용합니다.
Android 실행 소스와 com.mobi.passenger 앱 ID를 추가했습니다. 기존 임시 앱(com.mobi.local.mobi_ble_temp)과 별도로 설치됩니다.

```powershell
cd mobi-smart-transport-ai/apps/passenger_app
flutter pub get
flutter run -d DEVICE_ID --debug
```

Flutter 3.41.6 / Dart 3.11.4, Android SDK 36, JDK 21 환경에서 작업했습니다. Android minSdk는 28입니다.
Windows 한글 경로에서 기존 voice_aurora.frag 셰이더 도구가 실패하면 저장소 전체를 영문 경로에 두어 같은 명령을 실행합니다. 셰이더 소스/기존 음성 기능을 삭제하지 않습니다.
로컬 SDK 경로, build 폴더, APK, keystore는 소스 업로드 대상이 아닙니다. 단계별 변경은 ajh_2semester 브랜치에서 관리합니다.

### 실제 하드웨어 사용 순서

1. 비콘 A C3:00:00:5C:B9:47, B C3:00:00:5C:B9:48, WT901BLE68 F1:35:40:62:CD:43 전원을 켭니다. 제조사 앱의 센서 연결은 해제합니다.
2. 골전도 이어폰을 휴대폰에 연결하고 앱에서 주변 기기/정확한 위치 권한을 허용합니다. Bluetooth와 위치 기능을 켭니다.
3. 목표 버스를 선택합니다. A=502번 역할, B=511번 역할은 이 기기의 테스트 매핑이며 실제 노선 인증이 아닙니다.
4. 센서를 머리에 고정하고 **센서 연결** 후 정류장에서 도로 정면을 바라본 상태로 **도로 정면을 기준으로 설정**합니다. 장착 방향에 따라 좌우가 반대이면 정지 후 반전 옵션을 사용합니다.
5. **버스 탐색 시작 (5분)**을 누르고 실제 수신을 확인한 다음 **버스 소리 시작**을 누릅니다.
6. 비콘을 왼쪽에서 가까이 이동 → 정면에서 잠시 유지 → 오른쪽으로 멀리 이동합니다. RSSI가 강해질수록 목표음 간격은 짧아지고 약해질수록 길어집니다(약 220~1400ms).
7. 다른 테스트 버스의 신호가 -60dBm 이상이고 목표보다 6dB 이상 강하거나 목표가 미수신이면 오탑승 주의 경고음을 우선합니다. 이때는 해당 비콘을 멀리 두거나 목표 버스를 올바르게 선택합니다.

도로 기준 방향은 왼쪽 접근 -90~-30°, 정면 정차 0°, 오른쪽 출발 +30~+90° 가정입니다. 실제 머리 Yaw를 빼서 이어폰의 5방향 출력을 보정합니다.
정차 추정은 보정 RSSI -55dBm 이상이 1.5초 이상/3샘플 이상 유지되는 조건입니다. 정차 이후 기준 최고 신호보다 8dB 이상 약한 상태가 0.8초 이상/3샘플 이상 유지되면 오른쪽 출발로 추정합니다. 단일 급변에는 전환하지 않습니다.
3초 이상 신호가 끊기거나 버스/탐색을 새로 선택하면 해당 흐름을 초기화합니다. 실제 승차 여부·차량 방위·물리적 정차를 BLE로 확정하지 않습니다.
센서 수신 1초/비콘 수신 3초 이상 지연, 이어폰/오디오 포커스 해제, 화면 이탈, 5분 경과, 기준각/목표 변경 시 소리를 중지합니다. 자동 재시작하지 않습니다.
일반 목표의 상대 방향이 전방 5방향 범위(좌우 5° 여유 포함 ±95°) 밖이면 중지합니다. 위험/오탑승 경고의 대상이 뒤쪽이면 화면에 후방·무방향 경고임을 표시하고 좌우 균등한 경고음을 사용합니다. 정밀 360° HRTF 출력은 아닙니다.

### Mock 데이터 테스트와의 구분

첫 화면의 Mock 데이터 테스트에서는 기존 예시 시나리오를 사용합니다.
실기기 연동확인에는 예시 재생 기능이 없으며 실제 BLE/WT901/골전도 입력·출력만 확인합니다.
기존 mock_scenario 코드와 예시 정의는 변경하지 않습니다. 목표 버스 변경 시 소리만 정지하며 센서 연결은 유지합니다.

### 검증

```powershell
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
```

Bluetooth는 실제 Android 기기가 필요합니다. 자동 테스트는 가짜 무선 스트림과 네이티브 채널을 사용하므로 실기기 청취 검증과 구분합니다.

2026-10-25 실기기 전용 화면 검증: analyze 문제 없음, 전체 테스트 56개 PASS, Android APK 빌드 및 무선 설치·실행 성공. 기존 web release는 이전 연동 버전 검사 결과입니다. 추가 실기기 청취 검증은 별도입니다.
