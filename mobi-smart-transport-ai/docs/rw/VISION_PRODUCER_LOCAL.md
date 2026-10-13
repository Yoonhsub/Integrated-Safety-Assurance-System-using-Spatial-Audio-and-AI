# Vision Producer v2 — 로컬 인증·Binding 검증

## 구현 경계

Firebase Auth Emulator의 실제 ID 토큰 검증과 서버의 현재 `mobi_role`로 Producer를
인증한다. 역할은 `vision_producer`이며 UID 자체가 producerId다. 토큰에 남은 예전
role 대신 Admin SDK `get_user`의 현재 custom claims를 사용한다. 기존 check_revoked,
disabled 검사 및 401/403/503 정책을 재사용한다.

현재 v2는 **로컬 제출 검증과 영속 멱등성 기록**을 수행한다. 정상 요청은 202로 수락하되 안전 이벤트
저장, guidance 상태 변경, 승객 전송, 음성 안내는 하지 않는다. `accepted=true`는
현재 인증·Binding·payload 검증 통과와 receipt 커밋 확인을 뜻하며 안전 이벤트 저장/안전 판정을 뜻하지 않는다.
응답 유실 시 같은 이벤트의 최초 receipt를 반환한다. stored=false는 Safety Event 저장이 비활성이라는 뜻이며 RTDB 멱등성 metadata 저장까지 없다는 뜻은 아니다.

운영 OIDC 서비스 인증은 미구현이다. 운영에서 이 경로는 503으로 닫힌다. v1의
`POST /ai-vision/events`는 여전히 admin-only이며 기존 HTTP client도 v1 그대로다.
Flutter 앱과 Streaming 브랜치는 변경하지 않는다.

## 실행과 계정 준비

기존 `scripts/local_demo.ps1` / `local_demo.py`의 demo 환경을 사용한다. Auth
`127.0.0.1:9099`, RTDB `127.0.0.1:9000`, project `demo-mobi-local`의 정확한 조합만
허용한다. `APP_ENV=local-demo`, `MOBI_LOCAL_DEMO=1` 및 기존 guard의 모든 조건이
필요하다. 하나의 backend worker만 실행한다.

프로젝트 루트 PowerShell:

```powershell
# 기존 로컬 에뮬레이터를 먼저 시작한 상태에서 실행한다.
& backend/api/.venv/Scripts/python.exe -B scripts/provision_local_vision_account.py --email vision-producer@example.test
& backend/api/.venv/Scripts/python.exe -B scripts/provision_local_vision_account.py --email vision-operator@example.test --role admin
& backend/api/.venv/Scripts/python.exe -B scripts/local_demo.py backend
```

비밀번호는 숨김 입력하며 저장하거나 출력하지 않는다. 기존 계정의 비밀번호/역할을
덮어쓰지 않는다. 첫 명령의 UID가 producerId다. operator는 로컬 관리자이며 앱에
넣지 않는다. 인증 토큰은 Emulator 이메일/비밀번호 로그인
`http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-local`
의 ID 토큰을 사용한다. 토큰은 프로세스 메모리에서만 보관하고 모든 보호 요청에
`Authorization: Bearer <ID token>`으로 보낸다. 인증용 자격증명/토큰 파일을 커밋하지 않는다.
Producer 자동 토큰 갱신 client는 후속 작업이다. 기존 v1 client로 v2를 호출할 수 없다.

## 권한과 요청 순서

| 경로 | 역할 | 의미 |
|---|---|---|
| PUT /ai-vision/v2/cameras/{cameraId} | admin | camera를 producer UID 및 live/replay로 등록 |
| POST /ai-vision/v2/bindings | admin | 등록 camera를 서버가 소유자를 아는 기존 세션에 연결 |
| DELETE /ai-vision/v2/cameras/{cameraId}/bindings/{bindingId} | admin | 정확한 현재 Binding 폐기 |
| POST /ai-vision/v2/events | vision_producer만 | 자신에게 등록된 Binding으로 제출 |

1. 승객이 자신의 토큰으로 `POST /guidance/session` (`{}`)을 호출해 서버 sessionId를 받는다.
2. operator가 camera를 등록한다: `{"producerId":"<실제 UID>","sourceType":"live"}`.
3. operator가 Binding을 만든다:
   `{"cameraId":"camera-a","sessionId":"<서버 sessionId>","ttlSeconds":900}`.
   ownerUid는 body로 받지 않고 세션에서 도출한다. sessionId는 권한 증명이 아니다.
4. 응답의 bindingId/cameraEpoch/producerId/sessionId/sourceType을 Producer에 전달한다.
   이 값들은 Bearer 토큰을 대체하지 않는다. Producer/승객/기사는 연결을 생성하거나
   다른 camera를 등록할 수 없다. admin도 Producer를 가장해 v2 event를 제출할 수 없다.
5. 종료 시 operator가 DELETE한다. 사용자 END_CONVERSATION, session reset/recreation도
   기존 연결을 무효화한다. 앱의 단순 로그아웃을 서버 종료 신호로 자동 연결하지는 않았다.
   명시적 종료/해제나 Binding 만료가 필요하다.

TTL 기본 900초, 최대 3600초는 **관리 연결 유효 기간**이며 프레임 신선도 기준이 아니다.
벽시계 만료 및 단조 시계 deadline 양쪽을 검사한다. rebind/register는 이전 epoch를
폐기한다. session 종료·BOARDED·reset·재생성·서버 재시작 뒤 이전 Binding은 거부한다.
종료된 세션은 새 세션 생성 또는 reset 뒤 새 Binding을 만들어야 한다.

## 저장 및 동시성 한계

guidance store는 메모리가 lifecycle 원본이며 RTDB 사본에는 owner가 없다. 따라서
RTDB 사본을 신뢰해 연결을 복원하지 않는다. Camera/Binding은 같은 프로세스의
메모리에만 보관하며 재시작하면 재등록한다. 영속/다중 worker 배포는 지원하지 않는다.
분리된 worker에서는 알 수 없는 Binding을 거부하므로 로드밸런싱 성공을 보장하지 않는다.

Binding RLock → session RLock 순서로 소유자·generation·만료 확인까지 잠근다.
등록/재연결/해제는 같은 Binding lock으로 직렬화한다. reset/close는 같은 session
lock으로 이전 generation을 폐기한다. 종료/재연결과 동시인 제출은 해당 변경 전후의
선형화 시점에 따라 수락/거부되며 변경 완료 후 이전 Binding은 거부된다.

## v2 envelope

정확한 스키마: `packages/shared_contracts/api/vision_v2.request.schema.json`.
DetectionResult는 기존 `vision_detection.response.schema.json`을 참조한다.

```json
{
  "envelopeVersion": "2.0.0",
  "producerId": "<Firebase UID>",
  "cameraId": "camera-a",
  "sessionId": "<서버 session ID>",
  "bindingId": "<서버 UUID>",
  "cameraEpoch": "<서버 UUID>",
  "visionEventId": "<이벤트 UUID>",
  "sourceType": "live",
  "capturedAt": "2026-10-13T00:00:00Z",
  "frameIndex": 0,
  "detectionResult": {
    "schemaVersion": "1.0.0", "source": "webcam", "status": "ok",
    "frameId": "11111111-1111-4111-8111-111111111111",
    "capturedAt": "2026-10-13T00:00:00Z",
    "modelInfo": {"provider": "mock", "name": "example-only"},
    "detections": []
  }
}
```

위 UUID placeholder는 실제 서버 응답으로 대체해야 한다. replay는 sourceType=replay,
DetectionResult.source=video_file을 사용한다. 아직 지원 입력은 이 두 가지다.
frameIndex는 bool 아닌 0 이상 정수, 두 capturedAt은 같은 시각이어야 한다.
class/name pairing, confidence, status/error, bbox 정규화 및 이미지 경계·유한수를
검증한다. 알 수 없는 필드(userId 포함)는 거부한다. client 시간/출처는 선언값이며
이를 센서 관측 사실로 인증하지 않는다. model provider가 mock이어도 안전 증거로 승격하지 않는다.

응답: event ID, binding ID, 서버 receivedAt과 함께
`accepted=true, stored=false, guidanceEligible=false, freshnessVerified=false,
mode=local-validation-only`. Live 선언 프레임에는 아래 서버 시간 범위·순서 검사를 적용한다.
이 검사를 통과해도 **실제 촬영 시각의 진위나 Live 안전성이 입증된 것은 아니다**.
no_event 해석과 안전 판단은 이 endpoint에서 하지 않는다.

## 검증 및 다음 단계

```powershell
& backend/api/.venv/Scripts/python.exe -B -m pytest backend/api/tests/test_vision_v2.py backend/api/tests/test_security.py -q -p no:cacheprovider
# 실제 Auth/RTDB Emulator가 위 고정 주소에 준비됐을 때만:
& backend/api/.venv/Scripts/python.exe -B scripts/smoke_vision_producer.py
```

단위 테스트는 verifier를 Mock하며 운영 인증 우회 코드를 추가하지 않는다.
통합 smoke는 실제 Emulator 계정/ID 토큰을 만들고 HTTP 인증 의존성을 그대로 사용한다.
임시 계정 및 자신이 생성한 RTDB 세션만 finally에서 삭제한다. RTDB를 통째로 지우지 않는다.
카메라/모델/실제 배포 인증을 검증하는 스크립트는 아니다.

다음 단계: 영속 세션 소유권/lifecycle 정책 → production 서비스 신원과 실제 카메라 지연 측정 →
향후 Safety Event/outbox 원자성 → 소유권 있는
승객 관찰 안내 → Streaming 이식. 현 v2는 안전 이벤트를 저장하지 않으므로 재전송이 중복 안전
이벤트를 만들지 않는다. 영속 멱등성은 아래 정책을 적용한다.
기존 BLE 목표 식별·신선도, Vision 관찰 문구, Live Hold는 그대로 유지한다.


## Emulator 포트 충돌 진단 및 실제 HTTP 검증 (2026-10-13)

이번 시작 실패는 기존 `demo-mobi-local` Emulator가 네 포트를 이미 점유한 상태에서
두 번째 인스턴스를 실행한 것이 원인이었다. 정상적인 기존 Auth/RTDB 및 두 웹 앱을
종료하지 않고 재사용했다. 제한된 도구 환경에서는 CIM/loopback 조회가 막힐 수 있으므로
조회 실패나 빈 결과를 포트가 비었다는 증거로 해석하지 않는다.

- Auth/hub/logging: 127.0.0.1의 9099/4400/4500, 같은 node 프로세스.
- RTDB: 127.0.0.1:9000, 해당 node의 java 자식 프로세스.
- 기존 데모: backend8001, passenger5173, driver5174 유지.
- 검증용 최신 backend: 별도의 127.0.0.1:8011, 단일 worker, 같은 demo Emulator.
- IPv4 예약 포트는 50000~50059로 해당 네 포트와 겹치지 않았다.

진단 시 `scripts/local_demo.ps1 -Action Status -WorkDir <기존 runtime 폴더>`와
hub `http://127.0.0.1:4400/emulators`, backend `/health`를 확인하고, PID/parent 및
실행 명령의 project를 대조한다. 기존 인스턴스가 정상이라면 다시 시작하지 않는다.
방화벽 비활성화나 임의 프로세스 종료는 필요하지 않다.

최신 코드를 이미 실행 중인 backend에서 검증할 때:

```powershell
& backend/api/.venv/Scripts/python.exe -B scripts/smoke_vision_producer.py --backend-url http://127.0.0.1:8011 --report <저장소_밖_결과.json>
$env:RUN_LOCAL_RIDE_CONCURRENCY = '1'
& backend/api/.venv/Scripts/python.exe -B -m pytest backend/api/tests/test_ride_request_concurrency.py -q -p no:cacheprovider
Remove-Item Env:RUN_LOCAL_RIDE_CONCURRENCY
```

`--backend-url`은 http://127.0.0.1:<port>만 허용한다. 이 모드는 실제 네트워크 HTTP를
사용하고 앱의 인증 의존성을 교체하지 않는다. 옵션을 생략하면 기존 TestClient 모드다.
보고서는 두 모드를 구분하며 토큰/비밀번호를 기록하지 않는다. 무작위 카메라·계정·세션을
사용하고 테스트 Binding을 해제하며 자신이 생성한 RTDB 세션과 Auth 계정만 정리한다.
카메라 등록 및 backend 세션의 메모리 잔여 항목은 전용 검증 backend 종료 시 폐기된다.
기존 사용자 demo 계정/시연 데이터는 삭제하지 않는다.

이번 검증이 끝난 뒤 임시 8011 backend는 종료했다. 8011 예제 명령은 해당 backend를
다시 실행한 뒤 사용해야 한다. 기존 8001은 종료/재시작하지 않아 실행 당시 코드가 계속
동작한다. 최신 v2를 기존 데모에 반영하려면 시연을 중단할 수 있는 시점에 backend만
계획적으로 재시작하고 카메라/Binding을 새로 등록해야 한다.


## 프레임 순서·만료·연결 소실 정책 (2026-10-13)

Live 선언 입력은 서버 수신 시각에 대해 최대 나이와 미래 허용 차이를 검사한다.
같은 Binding/epoch의 frameIndex는 엄격하게 증가해야 하며 capturedAt은 감소하면 안 된다.
직전 frameId를 다시 쓰는 것도 거부한다. 누락·형식 오류·timezone 없는 시각은 현재 시각으로
대체하지 않는다. 새 optional `captureClock`은 unknown(기본)/host_read/sensor를 구분하지만
모두 Producer의 선언이며 서버가 센서 시각을 입증한 정보는 아니다.
OpenCV read 완료 시각을 실제 센서 촬영 시각으로 바꾸어 해석하지 않는다.

환경 변수는 서버 프로세스 시작 전에 지정한다:

| 설정 | 로컬 기본값 | 목적 |
|---|---:|---|
| MOBI_VISION_MAX_FRAME_AGE_SEC | 5초 | Live 선언 timestamp 최대 나이, 경계 포함 거부 |
| MOBI_VISION_FUTURE_SKEW_SEC | 1초 | 허용 미래 시각 차이, 이를 초과하면 거부 |
| MOBI_VISION_OBSERVATION_TTL_SEC | 3초 | 마지막 수신 이후 관찰 보존 상한 |
| MOBI_VISION_CONNECTION_TIMEOUT_SEC | 5초 | 새 수락 프레임 없는 연결 소실 시간 |

이 값은 **미실측 로컬 개발 기본값**이다. 운영 안전 임계값이 아니며 실제 촬영→read→추론→
전송 지연과 카메라 버퍼/시계 오차를 측정한 뒤 별도 확정해야 한다. 잘못된 설정은 503으로
거부하며 조용히 기본값으로 대체하지 않는다. 이 경로는 계속 로컬 전용이다.

관찰 유효기간은 observation TTL과 capture age 잔여 기간 중 짧은 쪽이다. 허용된 미래 시각이
TTL을 늘리지 않는다. 수신 후 경과와 연결 소실은 서버 단조 시계로 계산한다. 서버 벽시계와
단조 경과의 차이가 허용 skew를 초과하면 관찰을 무효화하고 새 제출을 503으로 거부한다.
새 Binding으로 다시 연결해야 한다. 이것은 실제 카메라 시계 신뢰를 검증하는 기능이 아니다.

`GET /ai-vision/v2/cameras/{cameraId}/state`는 admin 또는 등록된 Producer만 호출한다.
Binding·세션·generation을 다시 확인하고, 새로운 영상이 없어도 조회 시 만료/소실을 계산한다.
관찰 상태: unknown/observed/no_detection/unavailable/error/expired/ineligible.
연결 상태: waiting/connected/lost/closed/replay. no_detection은 안전함이라는 뜻이 아니다.
연결이 lost면 TTL이 더 길더라도 기존 관찰은 expired로 처리한다. unavailable은 lost로
표시하고 error는 추론 실패 상태를 보존한다. heartbeat만으로 관찰 시간을 갱신하는 기능은 없다.

조회 응답은 마지막 수락 frameIndex/epoch/capturedAt/서버 receivedAt 및 captureClock을
제공한다. 세션 종료/Binding 만료·해제 후에는 관찰 정보를 unknown으로 처리한다.
replay는 과거 timestamp를 허용해 재생 검증할 수 있으나 언제나 ineligible/replay이며
Live 관찰·BLE·guidance 상태를 갱신하지 않는다. 원본 영상 시각과 재생/read 시각의 상세
media PTS 계약은 아직 미구현이다. 같은 epoch의 순서 검사는 replay에도 적용한다.

동일한 Binding lock→session lock 구간에서 권한 확인, 프레임 검증 및 watermark 갱신을
마친다. 거부된 요청은 마지막 frameIndex/receivedAt/관찰 TTL을 갱신하지 않는다.
자연스럽게 경과한 시간에 따른 만료 플래그만 재계산될 수 있다. 새 Binding은 epoch와
watermark를 새로 만들며 이전 epoch는 거부한다. 연결 소실 후 같은 epoch의 더 높은 번호·
새 시간 범위의 프레임을 수신하면 다시 관찰할 수 있으나, 이것이 카메라 재연결 증거는 아니다.
실제 재연결은 관리 API로 새 Binding/epoch를 발급해야 한다.

응답 정책:

- 성공: 기존 202 및 accepted=true/stored=false/guidanceEligible=false/freshnessVerified=false.
- 시각/형식/필수 필드 오류: 422.
- 중복·역순 번호/감소한 촬영 시각/오래된 Live 프레임/과도한 미래 시각: 409.
- 이전 epoch/다른 카메라·세션/만료·해제 Binding: 403.
- 인증 오류: 401. 검증 서비스·시간 설정·서버 시계 불일치: 503.

순서 검사는 이벤트 멱등성과 분리한다. 동일 event ID/본문은 아래 영속 receipt를 반환하며,
새 event ID로 같은 frameIndex를 사용하면 409다. 실제 Safety Event와 outbox는 아직 비활성이다. 다중 worker를 지원하지
않으며 서버 재시작 후 기존 관찰/Binding은 복원하지 않는다.


## 영속 이벤트 멱등성 (2026-10-13)

검증 순서: Firebase ID token/현재 role → Producer UID 일치 → 현재 Camera/Binding/epoch →
세션 owner/generation/종료/만료 → body fingerprint → RTDB Transaction.
현재 권한이 없는 요청은 예전 receipt를 조회/반환하지 않는다. 조회 전의 권한 검사를
기존 event ID가 대체하지 않는다. 해당 요청의 schema validation도 그대로 유지한다.

저장 경로는 `/visionProducerLedger/<SHA256(verified Producer UID)>`다:

```text
version: 1
producerUid: server-verified UID
events/<SHA256(visionEventId)>:
  fingerprint, producerUid, visionEventId, cameraId, bindingId, cameraEpoch,
  sessionId, ownerUid, sessionGeneration, sourceType, frameIndex,
  firstProcessedAt, bindingExpiresAt, retentionPolicy, attemptId, response
streams/<bindingId>:
  cameraId, cameraEpoch, frameIndex, capturedAt, frameId, visionEventId, receivedAt
```

`events`와 `streams`는 같은 Producer 노드의 한 Transaction에 기록한다. 다른 경로에
receipt를 먼저 쓰고 watermark를 따로 갱신하지 않는다. callback은 DB snapshot에 대한
검사/새 값 생성만 수행하고 네트워크 호출/모델 실행/알림을 하지 않는다. SDK가 CAS를
재시도할 때마다 기존 receipt와 watermark를 다시 검사한다. 새 이벤트의 Binding 시간
만료도 재확인한다. 서로 다른 Producer의 같은 UUID는 다른 저장 namespace다.

fingerprint는 검증한 Envelope 전체를 key 정렬 JSON으로 SHA256 해시한다.
UTC timestamp와 정수형 실수 표현은 정규화하며 detection 배열 순서는 유지한다.
카메라/epoch/세션/모델/출처/상태/좌표를 포함한다. captureClock 미제공은 기본 unknown과
같은 의미다. Authorization 토큰과 계정 비밀번호는 body에 없고 fingerprint에 포함하지 않는다.
본문 내용과 무관한 다른 요청을 같은 이벤트로 처리하지 않는다.

- 동일 Producer/eventId, 동일 fingerprint: 기존 202와 최초 response를 그대로 반환.
- 같은 키/다른 본문: 409 `VISION_EVENT_ID_CONFLICT`.
- 새 eventId의 중복/역순 frameIndex: 기존 409.
- 만료/해제/다른 session/old epoch: 403, receipt는 반환하지 않음.
- 쓰기 결과 불확실/저장소 장애/손상: 503, 메모리 fallback 없음.

중복 재전송은 capturedAt이 현재 시간 범위를 벗어나더라도 현재 Binding 권한이 유효하면
최초 receipt만 반환한다. 최초 receipt의 receivedAt도 유지한다. 새 관측·TTL 갱신·watermark
후퇴·재알림은 발생하지 않는다. 최신 프레임이 이미 더 높은 번호로 갱신돼도 이전 receipt를
반환할 수 있지만 최신 상태는 바꾸지 않는다. 응답에 duplicate flag는 추가하지 않았다.

메모리 Observation은 확인된 새 커밋의 보수적인 projection이다. RTDB 커밋 직후 응답이
유실되거나 프로세스가 죽어 캐시 반영이 누락돼도 persisted watermark는 receipt와 함께
남는다. 재시도는 최초 receipt를 반환하고 관찰 TTL을 다시 만들지 않는다. 이 경우 메모리
상태는 unknown/이전 상태로 보일 수 있으나 낮은 frameIndex는 영속 watermark로 거부한다.
다음 정상 프레임은 그 watermark를 넘겨야 한다. 이 캐시를 멱등성의 원본으로 사용하지 않는다.

**backend 재시작** 뒤 receipt는 RTDB에 남지만 Camera/Binding/세션은 복원하지 않는다.
이전 요청은 403이다. operator가 새 session/Binding을 발급하면 이전 eventId로 바꾼 본문은
409이며 새 사용자 행동/프레임에는 새 eventId를 사용해야 한다. 이 제한은 인증 우회를 막는다.
RTDB가 영속하다고 단일 프로세스 Binding이 다중 worker에서도 안전해진 것은 아니다.

보존 정책: 현재 자동 만료/삭제를 하지 않는다(`retain-no-automatic-deletion`). 같은 UID의
event ID는 Binding이 바뀌어도 재사용하지 않는다. 운영용 기간/용량 정책은 미확정이다.
큰 Producer 노드의 Transaction 비용은 누적되므로 장기/대규모 운영에는 별도 설계가 필요하다.
receipt를 수동 삭제하면 그 ID의 충돌/중복 이력도 사라진다. old Binding은 여전히 거부하지만
새 Binding으로 바꾼 본문의 같은 ID 재사용까지 보장할 수 없으므로 임의 pruning은 금지한다.
정리 정책을 추가할 때는 영구 tombstone 또는 세대별 재사용 금지 규칙을 함께 설계해야 한다.

**RTDB Emulator 프로세스**의 데이터는 기본적으로 메모리다. backend 재시작과 Emulator
재시작은 다르다. Emulator를 종료해 데이터가 사라지면 receipt도 사라진다. 같은 dataset을
복구하려면 Firebase CLI의 export/import를 저장소 밖에 보존해 재시작해야 한다. Auth UID도
같은 export로 유지해야 같은 Producer namespace를 복구할 수 있다. export에는 로컬 계정
정보가 포함될 수 있으므로 Git에 넣지 않는다. 이번 테스트는 기존 Emulator를 종료하지 않았다.

검증 명령:

```powershell
$env:RUN_LOCAL_VISION_LEDGER = '1'
& backend/api/.venv/Scripts/python.exe -B -m pytest backend/api/tests/test_vision_event_ledger.py -q -p no:cacheprovider
Remove-Item Env:RUN_LOCAL_VISION_LEDGER
& backend/api/.venv/Scripts/python.exe -B scripts/smoke_vision_producer.py --backend-url http://127.0.0.1:8011 --report <외부_결과.json>
```

`--restart-checkpoint <외부 경로>`는 테스트 coordinator가 자신이 실행한 backend를 재시작할
때만 사용한다. smoke가 `<경로>.ready`를 쓰면 backend를 재시작하고 `<경로>.continue`를
작성해야 한다. 토큰은 계속 실행 중인 smoke 프로세스 메모리에만 있으며 marker에는 없다.
기존 사용자 backend를 임의 종료하는 옵션은 제공하지 않는다. 180초 내 재시작 확인이 없으면
테스트가 실패한다. 재실행에는 새 marker 경로를 사용한다. 실제 HTTP smoke는 본인이 만든
Auth 계정/RTDB session/ledger만 정리하며 영속 receipt 삭제는 테스트 데이터 정리 용도뿐이다.

## 승객 관찰 전용 조회

`GET /ai-vision/v2/sessions/{sessionId}/observations`는 Firebase passenger(또는 서버 admin) 인증으로
활성 세션의 소유권을 검사한다. 타인/종료/존재하지 않는 세션은403, 미인증은401이다.
세션 재생성 generation, Binding 만료·해제·카메라 재등록 이후의 관찰은 반환하지 않는다.
응답 계약: `packages/shared_contracts/api/vision_observations.response.schema.json`.

응답은 `sessionId`, `observations[]`이며, 각 항목에 producerId/cameraId/sourceType,
cameraEpoch/frameIndex/visionEventId, 선언 capturedAt/서버 receivedAt, captureClock,
observedClasses/message, inferenceStatus, state(available/expired/lost), validForSeconds를 포함한다.
현재 UI 지원 class는 COCO mapping의 bus뿐이다. sourceType=replay는 반드시 녹화 시연으로 표시한다.
서버 메시지는 고정된 관찰 문구이며 Producer/LLM 문구를 그대로 노출하지 않는다.

관찰 projection은 RTDB producer ledger의 `streams/{bindingId}/observation`에 receipt/watermark와
같은 Transaction으로 기록한다. receipt와 projection은 다른 구조다. 동일 이벤트 재전송은
projection/서버 수신시각/TTL을 갱신하지 않는다. 승객 조회는 확인된 commit의 단일 프로세스
캐시만 읽고, 현재 Binding/세션 상태를 매번 확인한다. 재시작 후 영속 projection을 자동 복원하지
않으며 Binding부터 다시 발급해야 한다. 불확실한 commit은 cache에 반영하지 않는다.

Live TTL은 기존 정책을 사용하고 Replay preview TTL은 최초 서버 수신 기준 observation_ttl이다.
조회에서 만료/소실을 계산하며 만료된 class와 현재 관찰 문구는 숨긴다. 오류는 안전함을 뜻하지 않는다.
Flutter 관찰 카드가1초마다 기존 인증 HTTP Client로 조회하며 네트워크 왕복 시간을 차감한
validForSeconds로 로컬 만료를 처리한다. 조회 실패/세션 변경은 현재 표시를 지운다.
폴링 기반이므로 Binding 해제의 UI 반영에는 요청/폴링 지연이 있을 수 있고, 최대 표시 수명은
서버가 남겨준 TTL로 제한된다. 센서 촬영 시각을 검증한 것은 아니다.

`stored=false`는 기존 안전 이벤트 저장 비활성을 의미하며 변경하지 않는다.
`guidanceEligible=false`, `freshnessVerified=false`, 기존 Live Hold도 유지한다.
관찰 카드는 guidance 상태/LLM/TTS/Spatial Audio/승차 허용 API를 호출하지 않는다.
