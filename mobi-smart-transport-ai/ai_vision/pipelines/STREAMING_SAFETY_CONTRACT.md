# Streaming 안전 통합 계약 (설계, 아직 미구현)

기준: custom-training `aea0415`, 비교 Streaming `bedf1db`, 2026-10-13.
이번 구현은 taxonomy 안내 문구 수정과 회귀 테스트뿐이다. 아래 인증, 연결,
신선도, 멱등성은 후속 구현의 계약이며 현재 API가 지원한다고 해석하지 않는다.

## 1. 현재 경로 및 관찰/판단 경계

- `SafetyInterpreter`는 taxonomy reason의 `ko_message`를 선택한다.
  `bus_door_visible`와 클래스 fallback은 **버스 문이 보입니다.**로 통일한다.
  문이 열렸는지, 목표 차량인지, 발판/주변이 안전한지 확인한 의미가 아니다.
- 현재 단일 프레임 reason은 `bus_door_visible`, `bus_stop_recognized`뿐이다.
  bus/roadway/sidewalk/obstacle/tactile_paving만으로 접근, 이동, 충돌, 안전을
  단정하지 않는다. 그 클래스의 과거 context 기반 템플릿은 단일 프레임용이 아니다.
- `VisionSafetyPipeline` → HTTP client → `/ai-vision/events` → adapter →
  `SafetyEventService`는 메시지를 보존해 저장한다. backend는 현재 메시지를
  reason으로 재작성하지 않는다. 과거 문서의 재가공 가능 설명은 구현 보장이 아니다.
- legacy mock fixture는 사전 작성한 상황 예시이며 실시간 센서 증거가 아니다.
- Vision 저장 이벤트에서 승객 guidance/session/음성으로 자동 전달하는 연결은 없다.
  Live 승차 질문은 `v3_agent`의 로컬 Hold 응답을 사용하고 LLM에 판단을 위임하지 않는다.
  일반 대화의 자연어 필터는 모든 표현에 대한 안전성 증명이 아니다. 후속 연결은
  서버 정책이 선택한 고정 관찰 문구만 전달하고 producer/LLM의 자유 문장을
  승차 허용 판단이나 안전 음성의 입력으로 사용하지 않아야 한다.
- COCO YOLO 런타임 mapping은 bus만 지원한다. bus_door/bus_stop 회귀는 fixture이며
  custom 3클래스 모델 학습·실기기 검증 완료를 의미하지 않는다.

## 2. Producer 인증 (후속 구현 결정안)

| 환경 | 인증 | 권한의 신뢰 근거 |
|---|---|---|
| 로컬 시연 | Auth Emulator의 전용 producer 계정 ID 토큰 | 서버 등록 producer UID, camera 허용 목록, 별도 `vision_producer` 역할 |
| 배포 | 서비스별 단기 OIDC 토큰 + issuer/audience 검증 | 운영 서비스 주체와 producer registry 매핑 |

현재 `/ai-vision/events`는 admin 전용이고 HTTP client는 인증 헤더가 없어 그대로
연결하면 실패한다. 후속 구현에서 전용 producer 정책을 명시적으로 추가한다.
관리자 권한을 producer에 부여하거나 공개 endpoint로 전환하지 않는다.
운영 OIDC의 구체적 issuer/audience는 배포 대상 확정 후 등록하며 Firebase 사용자
토큰 검증과 혼용하지 않는다. 검증기 선택은 신뢰 설정에 따른다.

- `Authorization: Bearer`로만 전달. 로컬 계정 자격은 저장소 밖 보호된 설정,
  토큰은 메모리에 보관한다. 운영은 workload identity/ADC 등 관리 자격을 우선하며
  서비스 계정 JSON을 앱에 배포하지 않는다. Flutter에 producer 자격을 넣지 않는다.
- 토큰 만료 전 갱신, 401은 한 번 갱신 후 같은 이벤트 ID로 재시도. 계속 실패하면 중단.
  위조/만료/비활성/철회는 401, 인증된 주체의 scope 위반은 403, 검증 서비스 장애는
  503으로 거부한다. 403에 다른 계정으로 재시도하지 않는다.
- 503/네트워크 실패는 제한된 backoff 및 동일 ID 재시도. 데이터가 만료되면 최신
  관찰로 재전송하지 않는다. 로그에는 토큰/계정 비밀번호를 남기지 않는다.
- Emulator 토큰은 demo 프로젝트와 loopback 로컬 모드에서만 허용한다.
  서버의 역할/등록 상태는 요청마다 확인하며 캐시 도입 시 철회 지연을 명시한다.

## 3. 서버 검증 연결

`인증 주체 → producer registry → camera → active binding → session owner → event`

서버가 binding을 발급하고 producerId, cameraId, sessionId, ownerUid, source mode,
허용 작업, 유효 기간을 저장한다. 사용자 인증과 session 소유권 검증을 통과한
연결 요청만 서버가 승인하며 producer에게 사용자/세션을 임의 선택할 권한을 주지 않는다.
한 camera에는 기본적으로 하나의 active binding만 허용한다. 다중 승객 사용은 별도
명시적 권한 설계가 필요하다. 세션 종료/로그아웃/연결 해제/producer 철회 시 폐기한다.

요청의 bindingId는 조회 키일 뿐 권한 증명이 아니다. 서버는 매번 인증 주체, camera,
활성 상태, 세션 소유자를 대조하고 event의 사용자 ID는 registry에서 만든다.
다른 사용자 이벤트를 전역 recent 목록이나 broadcast로 앱에 전달하지 않는다.
승객 조회/WS 구독에서도 UID와 세션 소유권, 만료를 다시 검증한다.

## 4. Versioned transport envelope 제안

기존 DetectionResult v1 및 SafetyEvent 타입은 유지한다. strict additionalProperties
때문에 아래 필드를 기존 v1 payload에 임의 추가하면 안 된다. 후속 작업에서 명시적
v2 envelope/schema와 client 호환 정책을 함께 추가하고 v1은 관찰 저장에만 제한한다.

| 필드 | 소유자/규칙 |
|---|---|
| envelopeVersion | v2 명시, 현재 구현 아님 |
| bindingId, cameraId | 서버 등록/발급 값, 인증 범위 대조 |
| streamEpoch | 서버가 발급한 연결 세대, 재시작/재연결 시 새 값; 이전 세대 재활성화 금지 |
| frameId | 동일 프레임 재시도에서 유지하는 UUID |
| frameIndex | epoch 내 0 이상 단조 증가 정수; 샘플링으로 번호 누락 허용 |
| visionEventId | 전송 단위 UUID, event뿐 아니라 no_event/error에도 부여, 재시도에서 불변 |
| captureMode | live_camera / replay / still / mock; binding 설정과 일치 필수 |
| capturedAt | timezone 포함 관측 시각, 추론/전송 시각으로 갱신 금지 |
| captureClock | sensor / host_read; 시각 근거와 한계 명시 |
| mediaPositionMs | replay의 원본 영상 위치, 벽시계 촬영 시각과 구분 |
| interpretation | 기존 status/event 의미 유지, frame metadata와 envelope 일치 검사 |
| receivedAt | 서버가 생성하는 최초 수신 시각; 재시도로 갱신 금지 |
| producerId, ownerUid, expiresAt | 서버에서 도출; 요청 body로 권한 부여 금지 |

현재 OpenCV 코드는 read 이후 현재 시각을 찍는다. 이는 센서 촬영 시각을 입증하지
않고 버퍼 지연도 포함하지 않는다. host_read 자료는 지연/버퍼 상한을 입증할 때까지
실시간 안전 증거로 사용하지 않는다. replay를 현재 시각으로 다시 찍어 Live로 승격
하지 않는다. `ultralytics` provider 이름과 실제 captureMode는 별개다. 현재 adapter의
`ai_vision_live`/`inferenceMode=live` 표시는 실시간성 보장이 아니다.

## 5. 신선도 및 소실 정책

즉시 명세할 규칙: 잘못된 시각/metadata 거부, replay/still/mock의 Live 증거 사용 금지,
폐기된 epoch 거부, 동일 epoch 역순/중복 frame으로 최신 상태 갱신 금지, 실패를 안전으로
해석하지 않기. frameIndex와 capturedAt이 모두 watermark와 일관돼야 한다.
거부된 입력은 watermark나 TTL을 연장하지 않는다.

측정 후 설정할 값: 최대 capture-to-receive 지연, 허용 미래 clock skew, 관찰 TTL,
연결 소실 timeout, BLE/Vision 결합 최대 시각 차이, 음성 안내 유효 기간.
어떤 숫자도 현재 검증된 안전 임계값으로 지정하지 않는다. 명시적 검증 설정이 없으면
Live 안전 증거 자격은 false이며 Hold를 유지한다. 설정된 skew를 초과하는 미래 시각은
거부한다. 허용 skew 이내라도 음수 age를 이유로 TTL이 늘어나지 않도록 상한을 둔다.

서버 수신과 capture age 양쪽에 상한을 적용하고, 수신 후 경과는 단조 시계로 계산한다.
서버 재시작 시 메모리의 freshness를 복원해 유효하다고 추정하지 않고 새 관측 전 unknown.
다중 인스턴스에서는 공유 저장소의 epoch/watermark를 원자적으로 비교한다.
현재 읽기와 전송/음성 재생 직전에도 만료를 검사한다. 주기적인 만료 처리로 새 프레임이
오지 않아도 상태가 unknown이 되게 한다. 카메라 소실/error/unavailable은 관찰을
무효화하고, heartbeat만으로 관찰 TTL을 연장하지 않는다. 정상 no_event는 검출 없음일
뿐 안전 허용이 아니다. 영상 EOF는 replay 종료로 구분한다.

Vision과 BLE는 각각의 TTL과 출처를 따로 검증한다. Vision 도착이 BLE 시각을 갱신하면
안 된다. 둘의 시간 차이가 허용 범위를 벗어나면 결합하지 않는다. 유효하더라도 현재
Live Hold는 유지하며 실제 목표 차량/승차 안전성 정책 변경은 별도 승인 사항이다.

## 6. 재전송 멱등성 vs 반복 안내

- 저장 키: 서버에서 확인한 `(producerId, visionEventId)`의 안전한 해시 키.
  body userId를 namespace로 사용하지 않는다. canonical payload digest에 binding,
  epoch/frame, provenance, interpretation을 포함하고 토큰/receivedAt은 제외한다.
- 같은 키/내용은 최초 결과와 event ID를 반환. 다른 내용은 409. 권한이 철회됐으면
  기존 receipt도 노출하지 않는다. 이미 처리된 재전송은 저장만 재응답하고 최신
  관찰/TTL/음성을 다시 발생시키지 않는다.
- RTDB의 동일 transaction 경계에서 event+receipt+stream watermark와 상태를 반영한다.
  transaction callback에 HTTP/음성 등의 부작용을 넣지 않는다. outbox를 쓰면 그것도
  같은 원자 경계에 기록하고 consumer가 event ID로 중복 처리한다.
- 재시작/응답 유실에는 동일 ID와 불변 payload를 가진 내구성 있는 제한 크기 송신 큐로
  복구한다. 로컬 미전송 이벤트도 오래되면 안전 관찰로 보내지 않고 폐기/감사 처리한다.
- 보존 정책은 활성 binding 동안 receipt 유지, 종료 후 문서화한 최대 재시도 기간
  이상 유지. 구체적 기간은 용량/운영 정책 확정 필요. 삭제 후에도 폐기 epoch/만료
  binding을 거부하여 오래된 이벤트가 새 이벤트로 부활하지 않게 한다.
- 연속 프레임은 다른 이벤트다. 세션+reason+관찰 상태 기준 cooldown/상태 변화
  정책으로 음성 반복을 억제한다. 저장 멱등성과 분리하고 긴급도 상승은 별도 처리한다.
  현재 bbox/class만으로 같은 물체의 지속 ID를 입증할 수 없으므로 객체 추적을 가정하지 않는다.

## 7. 후속 구현 순서와 완료 조건

1. 전용 producer principal, registry, 서버 binding 및 v2 schema/client 인증.
   401/403/503, 타 사용자 세션/카메라, 만료/철회/Emulator 분리 테스트.
2. provenance, epoch/frame watermark, 만료/소실 상태, replay 격리.
   미래/지연/역순/재시작/무프레임/서로 다른 BLE 시각의 deterministic clock 테스트.
3. 원자 event/receipt 및 재시도. 실제 RTDB Emulator에서 경합·응답 유실·다중 인스턴스
   검증; 같은 ID 중복 저장과 반복 음성 억제 각각 검사.
4. 소유권 검증된 앱 구독과 고정 관찰 메시지 전달. 자유 LLM/producer 문구는 안전 안내로
   직접 읽지 않기. 정상 인증이 없는 전역 recent 또는 guidance/event 우회 금지.
5. 그 후 Streaming 코드 이식 및 Windows 영상/웹캠 검증. CPU 지연, 연결 소실,
   버퍼 누적, 카메라 재연결 측정. COCO bus와 fixture/custom 모델 결과를 구분한다.

실제 Windows 카메라, 운영 Firebase/OIDC, 세션 연결, TTL 및 중복 저장 방지는 이번
변경으로 구현되거나 검증되지 않았다. Streaming 통합 전 위 선행 항목이 필요하다.
