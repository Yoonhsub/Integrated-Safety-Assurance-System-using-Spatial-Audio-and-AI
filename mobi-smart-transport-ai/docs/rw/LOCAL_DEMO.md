# Windows 단일 PC 로컬 시연

온라인 배포, Blaze, 실제 Firebase 프로젝트 없이 `demo-mobi-local`의 Auth와
Realtime Database Emulator를 사용한다. 실제 사용자·운영 DB와 연결하지 않는다.

## 구성과 구현 경계

- 승객 웹: `http://127.0.0.1:5173`
- 기사 웹: `http://127.0.0.1:5174` (서로 다른 origin으로 로그인 세션 분리)
- FastAPI: `http://127.0.0.1:8001`; 기존 8000 서비스는 보존한다.
- Auth: `127.0.0.1:9099`, RTDB: `127.0.0.1:9000`, hub: 4400, logging: 4500.
- 이메일/비밀번호 로그인과 토큰 검증, 역할/소유권 검사, 요청 저장/조회/수락/취소는
  실제 로컬 에뮬레이터와 API를 사용한다. Mock 인증 의존성 주입을 사용하지 않는다.
- 노선·도착정보, 기사 배정은 가상 데이터다. `MOCK-502 → demo-driver-502`,
  `MOCK-105 → demo-driver-105`만 시연용 서버 배정표에 등록한다. 실제 차량 식별 근거가 아니다.
- 기사 수락 이후 승객의 **상태 조회** 버튼으로 서버 상태를 확인한다. 자동 푸시가 아니다.
- 홈의 안전/접근 정보는 기존 Mock이며 실시간 센서와 연결되지 않는다. Live 승차 허용은 계속 보류한다.
- 브라우저 WebSocket은 Authorization 헤더를 보낼 수 없어 현재 보호 WS와 연결되지 않는다.
  앱에 관리자 토큰을 넣거나 URL에 사용자 토큰을 넣지 않는다. 향후 단기·일회용 WS 티켓 또는
  검증된 same-origin 세션 방식을 별도 설계한다. `guidance/event`는 계속 관리자 전용이다.
- AI Vision 단일 이미지/스트림 코드와 BLE/공간음향 모듈이 존재해도 이번 요청 상태 흐름에
  실기기로 통합된 것은 아니다. 음성 외부 API 키는 로컬 런처에서 비운다.

## 준비 및 시작 (프로젝트 루트 PowerShell)

필수: 기존 Python virtualenv와 backend requirements, Node/Firebase CLI, Java 21,
Flutter SDK. 첫 에뮬레이터 실행에는 공식 JAR 다운로드, 첫 Flutter build에는 패키지
다운로드가 필요하다. 준비가 끝난 뒤에도 웹 엔진/CDN 캐시 여부에 따라 완전 오프라인은
별도 검증이 필요하다.

```powershell
$demo = 'C:\mobi-ai\local-demo'
.\scripts\local_demo.ps1 -Action Prepare -WorkDir $demo
.\scripts\local_demo.ps1 -Action Build -WorkDir $demo
.\scripts\local_demo.ps1 -Action Start -WorkDir $demo
.\scripts\local_demo.ps1 -Action Verify -WorkDir $demo
.\scripts\local_demo.ps1 -Action Status -WorkDir $demo
# 시연 후
.\scripts\local_demo.ps1 -Action Stop -WorkDir $demo
```

Prepare는 기존 출력 폴더를 덮어쓰지 않는다. 소스 수정 후에는 새 폴더에서 Prepare/Build한다.
Flutter/Java 경로가 다르면 `-Flutter`, `-JavaHome`을 지정한다.
Start는 점유 포트를 검사하고 다른 프로세스를 종료하지 않는다. 시작 실패 시 직접 시작한
프로세스만 정리한다. Stop은 PID와 시작 시각이 일치하는 프로세스 및 자식만 종료한다.
에뮬레이터 데이터는 종료하면 사라진다. 운영 데이터 import/export는 하지 않는다.
로그는 출력 폴더의 `*.stdout.log`, `*.stderr.log`, `*-debug.log`와 `verification.json`에 남는다.

## 계정과 시연 순서

아래는 이 demo 에뮬레이터에만 존재하는 폐기 가능한 계정이다. 공통 비밀번호: `LocalDemo123!`.

| 계정 | 역할 | 서버의 가상 기사 ID |
|---|---|---|
| demo-passenger-a@example.test | passenger | 없음 |
| demo-passenger-b@example.test | passenger | 없음 |
| demo-driver-a@example.test | driver | demo-driver-502 |
| demo-driver-b@example.test | driver | demo-driver-105 |

1. 승객 주소에서 passenger-a, 기사 주소에서 driver-a로 로그인한다.
2. 승객의 기존 에이전트 이름/모드 화면을 진행한다. 로컬 데이터는 시뮬레이션임을 설명한다.
3. 승객 홈에서 502번 선택 후 **탑승 요청하기**를 누른다.
4. 기사 홈에서 요청 목록을 새로고침하고 해당 요청을 수락한다.
5. 승객 홈에서 **상태 조회**를 눌러 ACCEPTED를 확인한다.
6. **내 탑승 요청 취소** 후 기사 목록 새로고침으로 CANCELLED를 확인한다.
7. 기사의 수락은 실제 승차 안전 허가가 아님을 설명한다. 센서 접근·안전 안내는 Mock과
   Live 보류 동작을 구분해 보여준다. 실제 탑승 지시로 시연하지 않는다.
8. 양 앱에서 로그아웃한 후 Stop한다.

역할은 seed 도구가 Admin SDK로 에뮬레이터에 등록한다. 앱이 역할/기사 ID를 스스로
등록하지 않는다. 서버는 UID, 현재 서버 claims, 계정 비활성화와 토큰 취소를 검사한다.
에뮬레이터 허용은 명시적 `APP_ENV=local-demo`, `MOBI_LOCAL_DEMO=1`, 정확한 demo project,
정해진 loopback host가 모두 일치해야 한다. 운영/클라우드 설정과 혼용하면 실패한다.

## 검증 구분

`smoke_local_demo.py`는 실제 로컬 에뮬레이터에서 로그인·토큰 갱신·비인가 차단,
요청 생성/수락/취소와 RTDB 규칙, 헤더 인증 WS 경계를 검사한다. 외부 모델과 하드웨어는
검사하지 않는다. 일반 pytest와 backend smoke의 Mock 성공과 구분해 보고한다.
기존 `smoke_v3_guidance.py`는 토큰 없이 보호/관리자 API를 호출하므로 이 서버에서 전체
시나리오가 통과하지 않는다. 이를 위해 운영 인증을 완화하지 않는다.

RTDB 규칙의 추가 필드 차단은 `$other: { ".validate": false }`로 처리한다.
RTDB에 없는 `childrenCount()`를 사용하지 않는다. 수정 규칙은 로컬에서만 로드한다.

참조: [Auth Emulator 연결](https://firebase.google.com/docs/emulator-suite/connect_auth),
[Emulator 설치](https://firebase.google.com/docs/emulator-suite/install_and_configure).


## 탑승 요청 동시성 검증

시연 스택이 실행 중일 때 프로젝트 루트에서 실행한다. 원본 운영 프로젝트는 사용하지
않으며, 검사 도구가 만든 고유 테스트 요청만 정리한다. 일반 pytest는 메모리를 쓰고
아래 opt-in 테스트만 실제 RTDB SDK 충돌/재시도를 사용한다.

```powershell
$env:RUN_LOCAL_RIDE_CONCURRENCY = '1'
& backend/api/.venv/Scripts/python.exe -B -m pytest backend/api/tests/test_ride_request_concurrency.py -q -p no:cacheprovider
Remove-Item Env:RUN_LOCAL_RIDE_CONCURRENCY
& backend/api/.venv/Scripts/python.exe -B scripts/smoke_ride_concurrency.py --output "$demo/ride-concurrency.json"
```

첫 명령은 인증 principal을 테스트에서 주입하고 실제 RTDB ETag 경합을 결정적으로
만든다. 둘째 명령은 실제 Auth Emulator 로그인 토큰과 HTTP API로 수락/취소,
중복 수락, 타 기사 접근, 취소 재시도 및 완료/취소 경합을 확인한다.
기존 V3 smoke의 무토큰 401은 예상된다. 후속 개선 시 사용자 세션용 토큰과
관리자 전용 fixture 호출을 분리해야 하며, 일반 사용자에게 관리자 권한을 주거나
보호 API를 공개해서 통과시키면 안 된다.


### 생성 멱등성 검증

```powershell
$env:RUN_LOCAL_RIDE_CONCURRENCY='1'
& backend/api/.venv/Scripts/python.exe -B -m pytest backend/api/tests/test_ride_creation_idempotency.py backend/api/tests/test_ride_request_concurrency.py -q -p no:cacheprovider
Remove-Item Env:RUN_LOCAL_RIDE_CONCURRENCY
& backend/api/.venv/Scripts/python.exe -B scripts/smoke_ride_idempotency.py --output "$demo/ride-idempotency.json"
```

앞 명령은 실제 RTDB + 주입 principal/FCM spy·장애 주입, 뒤 명령은 실제 로컬 Auth 토큰과
HTTP를 사용한다. 실제 FCM 기기 전송은 하지 않는다. 응답 유실은 성공 응답을 버리고 재시도하거나
저장 커밋 후 오류를 주입해서 검증한다. 네트워크 장비 장애를 실제 발생시켰다는 의미가 아니다.
