# AI Vision Observation 한국어 TTS

## 최신 검증 상태 — 2026-10-19 (KST)

PC Chrome의 현재 Web 빌드에서 사용자가 한국어 Observation 음성을 직접 청취했다. 일반 관찰 음성 → 개발용 모의 위험 안내의 선점 → 위험 구간 관찰 보류 → 시나리오 자연 종료 후 부모 화면 조작 없이 보류 표시 해제까지 확인했다.

TTS ON을 유지한 상태에서 실제 TFLite Replay를 잠시 정지해 서버의 `lost`, TTL 0, 빈 클래스와 Chrome의 카메라 연결 중단 표시를 확인했다. 이후 새 실제 프레임을 전달하자 사용자가 버튼 조작 없이 한국어 관찰 음성이 자동으로 다시 들린다고 확인했다. 같은 의미의 연속 프레임은 기존 중복 억제 대상이며, 이번 자동 복구 PASS는 관찰 만료·소실 뒤 새로운 유효 관찰이 도착하는 조건이다. 모든 새 프레임의 반복 발화를 의미하지 않는다.

- 실제 TFLite Replay: 138프레임, 인증된 v2 HTTP 202 138건, 오류 0건. 합성 DetectionResult를 주입한 결과가 아니다.
- 실제 로컬 Firebase Auth/RTDB 및 HTTP 통합 검사: 16 PASS. 세션 소유권, 401/403, 관찰 만료, Binding 해제를 포함했다. 검증용 Binding은 해제했다.
- Chrome Sources에서 사용자가 내보낸 실제 로드 `main.dart.js`, 5173 제공 파일, 디스크 Web 빌드의 SHA256이 모두 `9f76216d4cb8de15d700e282672980788510960da8361216c2d21d6ee804b592`로 일치했다. 최신 빌드 적용을 확인했다.
- 이번 Console 확인에서 새 `Uncaught Error` 또는 `Uncaught (in promise)`는 없었다. 과거 오류의 근본 원인은 미확정이며 재현되지 않았다는 결과만 기록한다.
- Flutter 전체 126 PASS, Production JS 대역 12 PASS, Dart Web 어댑터 대역 4 PASS, Web release/Android debug build PASS는 이전 자동 검증 결과다. 2026-10-19 Chrome 최종 검증에서 해당 전체 검사를 재실행하지 않았다.
- 기존 Backend, Firebase Emulator, Web 서버를 재시작하지 않았다. 실제 운영 Firebase를 사용하지 않았다.

Android 실기기, 브라우저·출력 장치 장애의 모든 경우, 실제 도로 안전성은 미검증이다. Vision 단독 목표 버스 확정·승차 허용은 불가하며 Live Hold를 유지한다. `stored=false`, `guidanceEligible=false`, `freshnessVerified=false`의 의미도 그대로다. Chrome 청취 PASS는 현장 안전성 인증이나 Android 실기기 검증을 의미하지 않는다.

아래 구현·검토 이력의 “Chrome 미검증”, “새 빌드 미적용”, “후속 검토 필요”는 각 기록 당시의 상태다. 과거 결과는 보존하며 현재 확인 범위는 이 절을 기준으로 한다.

## 동작과 안전 경계

승객 V3 화면의 `AI Vision 관찰` 카드에서 `Vision 음성 안내`를 켜면 본인 세션의 서버 Observation을 읽는다. 기본값은 OFF이며, 로그인 사용자 또는 세션 변경과 세션 초기화 시 다시 OFF가 된다. Android 로컬 추론 결과를 이 음성 경로에 연결하지 않는다.

발화 조건은 `available`, `inferenceStatus=ok`, `sourceType=live/replay`, 유효한 카메라·epoch·프레임·이벤트 식별자와 남은 TTL이다. 고정된 bus/bus_door 관찰 문구만 사용하며 서버의 임의 message나 LLM 문장을 읽지 않는다.

- Replay: `녹화 영상에서 버스와 버스 문이 감지되었습니다.`
- Live: `버스와 버스 문이 감지되었습니다.`

목표 버스, 접근 거리, 승차 허용은 안내하지 않는다. Live Hold와 Backend 안전 플래그는 그대로 유지한다.

## 반복·만료·취소

같은 출처와 클래스 집합의 연속 관찰은 다시 읽지 않는다. 객체 tracking을 새로 추정하는 기능은 아니다. 의미가 바뀌면 최소 8초 간격으로 최신 항목 하나만 대기한다. 이 간격은 UX 기본값이며 안전성이 실측된 임계값이 아니다.

동일 receipt의 유효 기한은 폴링으로 연장하지 않는다. 카메라/epoch별 역순 프레임과 같은 프레임의 다른 이벤트를 배제한다. 새로운 유효 프레임이 같은 의미를 확인하면 그 의미의 관찰은 계속 유효할 수 있다.

관찰 만료·소실, 빈 목록, Binding 해제, HTTP 오류, 세션 불일치, 로그아웃, 세션 초기화, 화면 폐기 시 현재 Vision 발화와 대기를 취소한다. 오래된 HTTP 응답과 준비 중인 TTS도 세대 검사로 차단한다. `Vision 음성 중지`는 현재/대기를 취소하고 ON을 유지한다. 계속 무음으로 유지하려면 OFF를 선택한다.

## 기존 안내 우선순위

기존 AudioHapticCueService와 MockScriptAudioService는 공통 SpeechPriorityCoordinator를 사용한다. 기존 안전·시나리오 안내가 시작되면 Vision 음성을 선점한다. 기존 cue 및 생성 음성의 우선권 수명을 분리해 생성 음성 완료가 활성 위험 cue의 우선권을 해제하지 않도록 한다.

Vision 취소는 자기 소유의 낮은 우선순위 발화만 중단한다. 시나리오 재생 중과 다른 화면에 가려진 V3 화면에서는 관찰 발화를 보류한다. SpatialCueService, Head Tracking, BLE 판단은 변경하지 않는다.

TTS 명령은 직렬화하지만 발화 완료 대기는 큐 밖에서 처리한다. flutter_tts Web에서 취소가 완료 Future를 끝내지 않거나 시작 전 대기 음성을 취소하지 않는 경우를 별도 취소 신호와 browser speechSynthesis.cancel로 처리한다. 실제 브라우저의 callback 경합은 Fake 테스트와 별도로 검증해야 한다.

## 엔진 오류

한국어 음성이 없거나 엔진 준비/재생에 오류가 나면 Vision 음성을 OFF로 바꾸고 카드에 오류를 표시한다. 텍스트 관찰과 로그인·탑승 요청 API는 유지한다. 준비 3초, 발화 30초 상한은 실행 관리값이다. 2026-10-19 PC Chrome의 한국어 출력은 사용자 청취로 확인했다. 다른 브라우저·음성 엔진과 Android 실기기 지원은 별도 검증이 필요하다.

## 초기 Chrome 수동 검증 준비 (과거 기록)

이번 구현 중 기존 서버를 재시작하거나 실행 중인 앱의 정적 파일을 교체하지 않았다. 새 Web 빌드는 별도 경로에 준비했다:

`C:\Users\lucid\.codex\visualizations\2026\10\05\01a10b2b-8699-7732-bb48-e2edbcfeaef6\live-audio-lifecycle-fixes-20261016\web-build`

현재 실행 중인 이전 앱에서는 새 음성 버튼이 보이지 않을 수 있다. 다음 안전성 검토 후 기존 정적 파일을 백업하고 새 빌드를 적용하는 단계를 별도로 진행한다. Backend 8001, Auth 9099, RTDB 9000은 유지하며 인증이나 CORS를 우회하지 않는다.

새 빌드 적용 후:

1. Chrome에서 캐시를 갱신하고 로컬 승객 계정으로 로그인한다.
2. 502번을 선택하고 V3 안내 화면을 연다. 음성 기본 OFF를 확인한다.
3. 디버그 도구의 현재 sessionId를 확인하고 기존 서버 승인 절차로 새 Replay Binding을 만든다. 해제된 이전 Binding을 재사용하지 않는다.
4. 검증된 TFLite Replay Runner를 실행한다. 카드에서 Replay 출처와 bus/bus_door 표시를 확인한다.
5. `Vision 음성 안내`를 ON으로 바꾸고 한국어 Replay 문구를 직접 듣는다.
6. 연속 동일 관찰의 중복 발화가 없는지 확인하고 중지/OFF를 각각 시험한다.
7. 기존 위험 안내가 Vision을 선점하는지 확인한다. Vision OFF나 만료가 기존 위험 안내를 끊지 않는지도 확인한다. Mock cue와 실제 안전 판단을 구분한다.
8. Replay 송신 중지, 관찰 만료, Binding 해제, 로그아웃, 세션 초기화, 화면 이동에서 발화와 대기가 남지 않는지 확인한다.
9. 한국어 엔진 오류와 서버 오류 시에도 탑승 요청·조회·취소가 동작하는지 확인한다.

## 초기 후속 안전성 검토 계획 (과거 기록)

**Astra Medium으로 독립 안전성 검토를 수행해야 한다.** 우선순위 수명, Web 취소/완료/error callback 경합, 세션·인증·화면 전환 시 취소, TTL·역순·중복 억제와 기존 안전 안내의 호환성을 집중 검토한다. 이번 작업에서 이 검토와 실제 Chrome 청취를 완료했다고 주장하지 않는다. 검토·배포·커밋은 자동으로 진행하지 않는다.

## 2026-10-15 안전성 검토 결함 수정

1. Web의 `speak()` null은 요청 접수 결과로 허용한다. Android의 null/0 및 Web의 명시적 0, 플랫폼 예외는 실패다. 요청 반환값을 실제 재생 완료로 사용하지 않는다. 완료·오류·취소 콜백은 별도로 처리한다.
2. 위험 cue는 첫 경고 출력과 반복 타이머를 먼저 시작한다. 음성 준비·완료는 별도 작업이므로 후속 공간 경고도 TTS를 기다리지 않는다. 중복 동일 cue에는 타이머를 추가하지 않으며, cue 교체·중지·dispose는 세대를 무효화한다. 출력 하나가 지연될 때 pulse가 겹치지 않게 하고 각 호출에 1초 상한을 적용한다. 출력 실패는 `warningError` 및 V3 오류 영역으로 알린다. 이 상한은 실행 관리값이며 안전성이 실측된 임계값이 아니다.
3. Web 생성 음성은 서버 done 수신 이후에도 JS의 모든 예약 오디오 버퍼가 ended가 될 때까지 우선권을 유지한다. 명시적 stop은 drain을 취소로 끝낸다. 오류·20초 상한에서는 자신이 소유한 버퍼를 중단하고 나서 play가 반환된다. 일반 Observation의 OFF·만료는 자기 low-priority run만 취소하며 안전 cue/생성 음성 lease를 해제하지 않는다. 생성 음성 재생과 cue 경고 타이머는 별도 세대다.
4. 복수 카메라는 응답 순서에 의존하지 않도록 정렬하고 Live/Replay별로 bus/bus_door 관찰 종류를 요약한다. 두 카메라 이상이면 `여러 카메라의 관찰에서` 또는 `여러 카메라의 녹화 영상 관찰에서`라고 명시한다. 같은 버스의 문이라는 객체 연관성, 개수·방향·거리·안전 상태는 추정하지 않는다. Live와 Replay는 별도 문장이다. 하나라도 기한이 끝나면 전체 발화를 중지하도록 가장 이른 TTL을 사용하며, 후속 유효 응답에서 다시 요약한다. 동일 의미의 카메라/프레임 반복은 발화를 늘리지 않는다.

공유 엔진의 stop에 3초 상한을 적용한다. native 취소의 method 반환과 실제 취소 콜백 사이의 간격도 확인하며, 2초 내 확인되지 않으면 엔진을 격리해 재사용하지 않는다. 독립 경고는 계속 시도하고 UI에 음성 오류를 표시한다. 격리 후 임의 자동 복구로 다른 음성을 겹치지 않으며 앱을 다시 열어 엔진을 초기화해야 한다. 플랫폼 콜백에는 발화 ID가 없으므로 실제 Android/Web의 지연·중복 콜백은 독립 재검토와 실제 기기 확인이 여전히 필요하다.

검증 명령:

```powershell
flutter test --no-pub
flutter analyze --no-pub
node --test test/web_audio_drain_test.cjs
```

신규 Flutter 검사는 실제 FlutterTts 및 MethodChannel 응답/콜백을 대역으로 공급한다. 브라우저 엔진을 실행하거나 실제 한국어 소리를 검증한 것이 아니다. Node 검사는 실제 production JS를 읽어 AudioContext 대역과 실행한다. 실제 Chrome에서는 정상 null 뒤 음성이 끝까지 재생되는지, 경고 시작·선점·종료 범위, 로그아웃/세션 전환 취소, 버퍼 재생 종료 및 사용자 제스처를 별도로 확인해야 한다.

수정 후 **Astra Medium 독립 안전성 재검토**를 진행한 다음 새 빌드를 적용한다. 기존 실행 서비스에는 자동 적용하지 않는다.

## 2026-10-15 재검토 후 추가 수정

음성 요청은 페이지 소유 SpeechRequestScope의 generation, 사용자 UID, sessionId, mounted 상태를 확인한다. stop/reset/logout/dispose는 정리 작업 전에 요청을 무효화한다. SpeechCancelled는 명시적 취소이며 Live→TTS/WAV fallback 대상에서 제외한다. 실제 장애의 fallback은 아직 유효한 동일 요청에서만 허용한다. 늦게 끝난 synthesize 응답도 재생 직전 확인한다. dispose된 음성 서비스는 새 요청을 거부한다.

위험 진동과 경고음은 서로 다른 in-flight 상태로 병렬 시작한다. 한 채널의 1초 관리 timeout은 그 채널만 중복 요청을 막으며, 다른 채널의 경고를 막지 않는다. 실제 native Future가 끝나지 않은 호출을 취소됐다고 가정하지 않는다. 이미 기기에 전달한 진동/시스템음 자체를 취소할 수 있다고 주장하지 않으며, 종료 후 추가 예약을 막는다.

Web 기본 공유 엔진은 BrowserSpeechEngine + mobi_tts.js를 사용한다. flutter_tts 4.2.5의 내부 playing 상태를 외부에서 고치거나 지연 후 재호출하지 않는다. 각 SpeechSynthesisUtterance가 독립적인 완료/오류/취소 상태를 소유해 오래된 이벤트가 새 발화 Future를 바꾸지 못한다. stop은 기존 발화를 먼저 취소 결과로 확정하고 speechSynthesis.cancel 후 브라우저 speaking/pending 해제를 확인한다. 20ms 조회는 고정 대기 후 성공 처리하는 지연값이 아니며 1.5초 상한은 실행 관리값이다. 종료 확인이 안 되면 안전하게 실패한다. 완료 콜백 누락은 Coordinator의 기존 30초 상한 후 stop으로 정리하며, 브라우저 출력이 해제된 경우 다음 유효 요청을 받을 수 있다.

Android의 flutter_tts 경로와 Web null 반환 허용 회귀는 유지한다. 기존 FlutterSpeechEngine의 Web 플랫폼 대역 테스트는 라이브러리 반환 계약 검사이고, 실제 Web 기본 경로는 새 BrowserSpeechEngine이다. JS 대역 검사는 production mobi_tts.js의 null 반환, 취소 콜백 누락, 늦은 이전 콜백, 정상 완료와 실패를 검사한다. 실제 Chrome 한국어 청취/사용자 제스처/엔진 장애 및 Android 실기기 검증은 별도다.

추가 검증 명령: `node --test test/web_audio_drain_test.cjs test/web_tts_lifecycle_test.cjs`.
수정 후 Astra Medium 독립 안전성 재검토가 필요하며, 새 빌드 적용·서비스 재시작·커밋은 별도 승인 없이 진행하지 않는다.

## 2026-10-16 Live 오디오 수명주기 및 종료 실패 보완

LiveAudioSession은 production Web 어댑터가 사용하는 요청 수명주기다. 요청별 generation과 idle/starting/playing/cancelling/cancelled/completed/failed 상태를 관리한다. 외부 stop/dispose는 await 전에 generation을 바꾸며 시작 대기, 소켓 연결, 첫 청크 콜백 뒤, PCM 출력 직전까지 같은 요청인지 확인한다. 이전 요청의 늦은 연결·종료·drain 콜백은 새 요청을 변경하지 않는다. firstAudio 콜백은 실제 스피커 출력 또는 촬영 시각의 증거가 아니다.

AudioShutdown은 출력 정리를 모두 시작하고 3초 관리 상한을 적용한다. 상한은 플랫폼 작업 취소나 안전성이 실측된 값이 아니다. 작업이 끝나지 않으면 기존 작업을 공유하고 중복 stop이나 새 재생을 실행하지 않는다. 작업이 늦게 성공하면 해당 보호만 해제한다. 명시적 실패 후에는 다시 중지를 요청하여 성공을 확인할 수 있다. 영구 미완료라면 채널 재사용을 보류하고 앱 재시작/출력 장치 복구가 필요하다.

MockScriptAudioService와 AudioHapticCueService는 TTS/네이티브 플레이어/Live/Web clip 정리를 독립 시도한다. 늦게 완료되는 native play 또는 clip fetch도 정리 장벽 안에서 기다린 후 다시 stop하여 이전 요청의 출력을 제거한다. 정리 실패 때 별도 quarantine 우선권을 유지하므로 일반 Observation이 끼어들지 않는다. 종료 확인 전 finally에서 보호를 무조건 해제하지 않는다. SpeechCancelled의 하위 오류인 AudioShutdownFailure는 fallback 발화 대상에서 제외한다. 실제 재생 실패는 동일 요청이 유효하고 출력 종료가 확인된 경우에만 기존 fallback을 허용한다.

TTS 종료 자체가 확인되지 않으면 Coordinator도 낮은 우선순위 출력을 계속 차단한다. 불확실한 TTS를 임의 복구하지 않으며 이 경우 앱 재시작이 필요하다. 독립 위험 경고음·진동은 계속 시도한다. 완료 이벤트 구독 정리는 오디오 출력 종료 확인과 분리하며, 구독 콜백은 generation/소유권으로 무효화한다.

mobi_live_audio.js는 source.stop 오류를 숨기지 않고 모든 source의 종료를 시도한다. 종료하지 못한 source는 추적을 유지하여 새 재생을 성공으로 간주하지 않는다. WebAudio의 성공한 stop 명령은 해당 브라우저 API 계약에 따른 확인이며 실제 스피커 청취 또는 하드웨어 안전성 인증이 아니다.

검사:
- flutter test / flutter analyze / Flutter Web 및 Android debug build
- node --test test/web_audio_drain_test.cjs test/web_tts_lifecycle_test.cjs
- dart compile js test/web_live_adapter_harness.dart -o <외부 테스트 출력>/web-adapter.js
- node test/web_live_adapter_test.cjs <외부 테스트 출력>/web-adapter.js

마지막 검사는 실제 Dart Web 어댑터를 컴파일하되 WebSocket/브라우저 출력은 대역으로 공급한다. 실제 Chrome 한국어 청취와 Android 실기기는 별도 검증이다. 수정 후 Astra Medium 독립 안전성 재검토를 먼저 수행한다.

기존 clip 음성도 stop 시 fetch/decode 완료 콜백을 무효화한다. 종료 오류를 Dart에 전달하고 취소 결과 false를 정상 완료 true로 승격하지 않는다. 공간 파라미터·경고 패턴 기능은 변경하지 않았다. Production JS 검증에 test/web_clip_lifecycle_test.cjs를 포함한다.

## 2026-10-16 상위 HTTP 취소 및 Clip dispose 오류 보완

더 나은 경로 조회는 HTTP 시작 전 SpeechRequestScope.captureLatest로 요청을 캡처한다. 페이지의 기존 음성 scope(UID/session/mounted), 현재 경로 객체, 안내 활성 상태도 함께 확인한다. SpeechRequest.receive가 응답 후 수락 전에 검사하고 UI 갱신 및 발화 직전에 재검사한다. 같은 originatingRequest를 음성 합성 및 fallback까지 전달하므로 과거 응답을 새 scope로 포장하지 않는다. 중지·초기화·인증 변경·dispose·새 경로 시작/활성화는 요청을 무효화한다. HTTP 자체를 강제 취소하는 구현은 아니며 늦은 응답의 부수효과를 차단한다.

페이지 Clip dispose는 observeAudioCleanup으로 성공/실패/3초 관리 상한을 관찰한다. 실패 또는 무한 대기는 민감정보 없는 고정 개발 로그로 보고하며 화면 setState를 호출하지 않는다. 다른 출력 정리는 독립적으로 계속 시작된다. 이 관찰 함수는 실제 출력 종료를 성공으로 바꾸거나 안전 우선권을 해제하지 않는다. 늦은 플랫폼 오류도 처리되지 않은 Future 오류로 남지 않도록 timeout Future에 연결한다.

회귀 test/route_audio_lifecycle_test.dart는 실제 제품의 captureLatest/receive/run 호출 경계를 Completer로 지연하여 취소·응답 역전·fallback과 최신 요청을 검사한다. Clip 정리 예외/대기와 Mock 서비스의 우선권 보호도 검사한다. 실제 V3 전체 화면·Firebase 로그인·Chrome 음성 청취를 수행한 테스트는 아니다. 실제 브라우저에서는 안내 중지/초기화 중 지연 응답과 로그아웃·화면 이동·Clip 종료 오류를 추가 확인한다.

수정 후 독립 안전성 재검토와 Chrome 실제 청취는 별도 단계로 남긴다. 실행 중인 앱에 새 빌드를 자동 적용하지 않는다.


### 길찾기 중지의 종료 오류 관찰

길찾기 중지는 기존 요청을 먼저 무효화한 뒤 `observeAudioCleanup`으로 `stopCue`의 오류와 관리 시간 초과를 고정 문구로 기록한다. 오류 내용·사용자 발화·토큰을 로그에 포함하지 않는다. 관찰 함수는 안전 lease나 성공 상태를 변경하지 않는다. 실제 종료가 미확인인 동안 기존 AudioShutdown 보호를 유지한다. 명시적 실패는 중지 재시도로 복구할 수 있으며, 영구 미완료 또는 TTS 엔진 격리는 앱/탭 재시작과 출력 장치 확인이 필요하다. 시간 초과는 출력 종료 증거가 아니다.


### 시나리오 비동기 취소 처리

Scenario Controller는 script/cue/stop 콜백의 Future를 즉시 관찰한다. SpeechCancelled는 정상 취소로 종료하며 재시도·fallback·lease 해제를 수행하지 않는다. AudioShutdownFailure는 SpeechCancelled의 하위 타입이지만 실제 종료 실패이므로 무시하지 않고 다른 예상하지 못한 오류와 함께 FlutterError.reportError로 원래 예외 및 stack을 보고한다. 타이머와 재생 순서·소유권·Live Hold는 변경하지 않는다. Chrome 콘솔 재검증에는 별도 새 빌드 적용 승인이 필요하다.

### V3 Scenario Observation 상태 구독 (2026-10-17)

V3의 ScenarioObservationBuilder가 기존 MockScenarioController를 AnimatedBuilder로 구독하고, builder 내부에서 최신 isPlaying을 Observation 카드의 priorityBlocked로 전달한다. 부모 화면의 다른 setState나 폴링 타이머에 의존하지 않는다. 시나리오 카드와 동일 Controller를 사용하며, 정상 종료·pause·reset 시 카드가 소유한 외부 lease만 기존 패널 로직에 따라 해제된다. 실제 안전 오디오 및 종료 미확인 quarantine lease는 건드리지 않는다.

Widget 회귀는 실제 V3에서 사용하는 builder, 실제 Controller, Observation 패널, Coordinator를 실행한다. 부모 rebuild 없이 시작/중지 반복, 실제 타이머 정상 종료, AudioShutdown 실패 보호, 새 관찰 발화·동일 문구 억제·만료 Replay 침묵·dispose를 검증한다. 전체 V3의 Firebase 로그인 및 Chrome 실음성을 재현한 테스트는 아니다.

Chrome Uncaught Error는 별도 미확정 문제다. 107308과 107908 스택을 동일시하지 않으며 이번 수정은 예외 처리나 오디오 엔진 동작을 변경하지 않는다. 새 빌드는 실행 중 서버에 자동 배포하지 않는다. 실음성 재검증 시 유효한 Replay 관찰과 새 빌드를 확인하고, 시나리오 종료 후 불필요한 보류 해제·새 문구 발화·Console 오류를 각각 확인한다. 같은 문구의 중복 억제 및 실제 종료 실패에 따른 보수적 보류는 유지한다.