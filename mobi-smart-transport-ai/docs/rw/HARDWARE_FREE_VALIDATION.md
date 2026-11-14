# 하드웨어 없는 검증과 로컬 빌드

이 문서는 Android 기기 연결, 실제 BLE 동작, 실서버 전환 없이 수행하는 로컬 검증 절차다. 자동 테스트 통과는 현장 인식률, 실제 차량 식별, 안전한 이동 경로 또는 이어폰 청감 검증을 뜻하지 않는다.

## 작업 경계

- 일반 소스 수정, fixture/mock 테스트, 소스 분석, 패키징, 로컬 APK 빌드만 포함한다.
- 로그인 우회, 실제 Firebase/공공 API 호출, 기기 설치/실행, 운영 트래픽 전환, 서명 키 교체, 권한 변경은 이 절차에 포함하지 않는다.
- 실제 장치 주소는 사람이 확인하고 입력한다. 비콘 번호/MAC 매핑은 시연 연결이며 차량 인증 자료가 아니다.
- WT 주소 설정은 임시 동시 테스트에만 적용된다. 기존 고급 진단의 기본 설정은 별도다.

## 로컬 테스트

아래 경로는 저장소 안의 `mobi-smart-transport-ai`를 기준으로 한다. 이미 검증된 개발 환경을 사용하거나 별도 가상 환경에 `backend/api/requirements-dev.txt`의 테스트 의존성을 준비한다. 운영 자격증명이 들어 있는 환경을 테스트 환경으로 사용하지 않는다.

```text
python scripts/run_backend_offline_tests.py
python -m unittest discover -s scripts/tests -v
```

첫 명령은 검토된 backend/public-data fixture 테스트를 실행하며, 기본 동기 HTTPX Client의 네트워크 transport를 차단한다. 명시적 transport, AsyncClient, requests, urllib, subprocess를 모두 격리하는 네트워크 sandbox는 아니다. 에뮬레이터/RTDB opt-in이 켜져 있으면 실행을 거절한다. 새로운 외부 호출 코드가 추가되면 guard 범위도 다시 검토해야 한다. 임시 테스트 디렉터리는 소스 밖에 새로 생성된다.

```text
cd apps/passenger_app
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

인증 패키지는 `packages/mobile_auth`에서 별도로 `flutter test`를 실행한다. 로컬 빌드 캐시가 생긴 작업 폴더를 배포 소스 패키지로 사용하지 않는다. `scripts/validate_architecture.py`는 생성 파일이 없는 소스 사본에서 수행한다.

### fixture 검증 범위

- 노선: MOCK/CACHE/PUBLIC_API/UNKNOWN 구분, 원본 updatedAt 유지, 미래/누락/오래된 시각, 새 빈 응답, 목적지 선택/실패 복구.
- Vision: 단일/다중/불확실/사용 불가, 좌우 경계, 저신뢰/빈 검출, 중복/역순/오래된 관찰, 취소와 상세창 갱신.
- 음향: 소프트웨어 출력 시작/완료/중지와 소유권, 중단 후 재생 간격. 실제 귀에 들린 시각은 측정하지 않는다.
- 장치 설정: 로컬 저장/초기화/검증, 늦은 비동기 완료, 화면 유지. 실제 Bluetooth 연결 성공은 검증하지 않는다.
- UI: 일반 휴대폰 크기의 두 화면, 숨겨진 화면 접근성 제외, 키보드, 확대 글자 대화상자.

## 자료 출처와 신선도

`PUBLIC_API`는 공공 API 자료라는 뜻이며 실제 차량 식별이나 승차 가능 확인이 아니다. `CACHE`는 저장 경로를 뜻할 뿐 원본이 LIVE임을 증명하지 않는다. 원본 자료 시각이 없으면 응답 생성 시각을 대신 넣지 않는다.

Backend 도착 캐시 TTL 기본값은 30초이며 `BUS_ARRIVAL_CACHE_MAX_AGE_SECONDS`로 0~300초를 지정한다. 0은 캐시 재사용을 끈다. TTL은 운영상 재사용 제한이지 안전 기준이 아니다. V3 live 경로는 출처가 검증되지 않은 공유 캐시로 LIVE를 대체하지 않는다. 앱의 30초 경고는 별도의 보수적 표시 기준이다.

카메라 시각은 앱의 프레임 수신 시각이다. 추론/처리 시간과 음성 소프트웨어 callback은 별도로 표시하며 촬영 노출 시각이나 실제 청감 지연으로 부르지 않는다.

## 배포 소스 준비

```text
python scripts/prepare_firebase_deployment.py backend --output <저장소_밖의_새_폴더>
```

이 명령은 로컬 패키지를 만들 뿐 배포하지 않는다. Vision 응답 JSON schema도 함께 포함되어야 한다. 준비된 패키지에서만 import가 되는지 별도로 확인하며, 이것을 컨테이너/실서버 검증으로 대체하지 않는다.

## 정상 Android 앱 빌드

JDK 21을 빌드 프로세스에 지정한다. 전역 Java 설정을 바꿀 필요는 없다. 공개 Android Firebase 앱 설정과 Backend origin만 담긴 설정 파일을 준비한다. Admin 자격증명이나 로그인 토큰을 넣지 않는다.

```text
python scripts/prepare_passenger_android.py --settings <정상_Android_설정.json>
python scripts/prepare_passenger_android.py --settings <정상_Android_설정.json> --flutter <flutter_실행파일> --build
```

정상 `lib/main.dart` debug APK를 만들며 설치하거나 실행하지 않는다. `app-debug.build-info.json`은 APK/포함 모델의 SHA256, 크기, Git 기준과 수정 여부를 기록한다. Firebase 키, 기기 주소, 로컬 경로는 기록하지 않는다. Backend data mode는 관찰하지 않았으므로 UNKNOWN이며 연결을 검사했다고 주장하지 않는다. 서명 검증과 실제 기기 검증도 별도다. 운영 배포용 서명 완료로 간주하지 않는다.

## 현재 보류와 현장 검증

WT 저장 설정 오류 시 연결 차단은 후속 명시적 승인 후 구현했다. 손상·읽기 실패 시 연결을 차단하고 복구 UI는 유지한다. 명시적 저장·초기화가 성공해야 연결이 다시 가능하며, 저장 설정이 없는 경우 기존 기본 동작은 유지한다. fixture 검증은 실제 BLE 대상·연결 검증을 대신하지 않는다.

실제 BLE/WT 재연결, 센서 부호/드리프트, 인식률, 배터리/발열, AirPods/Shokz의 좌우 청감과 실제 지연은 후속 실기기 검증 항목이다. 현재 작업에서는 기기 테스트와 운영 배포를 수행하지 않는다. 보안/운영상 필수 확인이 필요한 조치는 목록에 보류하고 독립적인 로컬 작업을 계속한다.
