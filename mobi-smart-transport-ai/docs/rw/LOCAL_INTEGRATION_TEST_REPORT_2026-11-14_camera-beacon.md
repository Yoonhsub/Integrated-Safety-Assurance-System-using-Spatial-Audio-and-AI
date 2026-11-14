# 2026-11-14 로컬 테스트 보고서: 카메라 미리보기와 Beacon

## 변경 사항

- 통합 테스트 화면의 compact 카메라 미리보기 높이를 100px에서 180px로 늘렸다.
- `DirectionAudioPanel`에 선택적 벽시계와 경과시간 입력을 추가했다. 미입력 시 기존 `DateTime.now()`와 `Stopwatch`를 그대로 사용한다.
- Beacon 패널 테스트의 550ms·1.1s 실제 대기를 결정적 시계 입력으로 바꿨다. radio-loss 경계와 센서 만료 기준은 기존 3초·1초 그대로 검증한다.
- Gemini `reasoningSource` 코드를 확인했다. 분류 서비스는 Gemini 응답이 없으면 `None`을 반환하며, 응답에서 유효한 비-UNKNOWN 분류가 나온 경우에만 `gemini`로 표시한다. 미설정 경로의 오표시를 재현하지 못해 로직은 변경하지 않았다.

## 검증

- 실행: `flutter test --no-pub test/concurrent_camera_panel_test.dart test/stationary_beacon_panel_test.dart`
- 결과: **25 tests passed**.
- 실행: `flutter analyze --no-pub lib/src/features/hardware_bus/concurrent_camera_panel.dart lib/src/features/hardware_bus/direction_audio_panel.dart test/concurrent_camera_panel_test.dart test/stationary_beacon_panel_test.dart`
- 결과: **No issues found** (84.4s).

## 범위와 한계

- Android 실기기·BLE/WT 실측과 실제 TAGO 호출은 수행하지 않았다.
- Gemini 자격 증명이 설정되지 않아 실제 Gemini 공급자 호출은 확인하지 않았다. 검토는 로컬 미설정 경로의 코드 흐름 기준이다.
- 커밋, 푸시, 병합, 배포는 하지 않았다. README는 수정하지 않았다.


## 2026-11-14 추가 독립 검증 및 정정

- Gemini 제공자 표기에 관한 앞선 판단을 정정한다. `auto` 모드에서 Gemini 응답이 없으면 `_generate`가 OpenAI fallback을 호출하고, 기존 `v3_agent.py`는 그 결과도 `reasoningSource: gemini`로 기록할 수 있었다. 현재 변경은 성공한 NLU 결과의 공급자를 요청별 ContextVar에 기록하고 trace에 `gemini` 또는 `openai`를 반영한다. Gemini/GCP 실서비스 호출은 하지 않았다.
- 추가한 fallback 회귀 테스트는 pytest를 구할 수 없어 실행하지 못했다. 로컬 Python 3.13에서 `pytest` 모듈이 없고, 사용 가능한 Anaconda pytest 실행기도 프로젝트의 `fastapi` 의존성 누락으로 conftest 단계에서 막혔다. 네트워크 설치는 하지 않았다.
- 카메라·비콘·compact 레이아웃 관련 Flutter 집중 테스트: 29 passed. 전체 passenger app Flutter suite: 717 passed, 9 skipped, 실패 없음.
- 변경된 UI/테스트 5개 파일 `flutter analyze --no-pub`: No issues found.
- 360x800 화면(컨테이너 590px)에서 180px 미리보기와 기존 컨트롤이 스크롤 없이 보이고, 360x600 및 2x 글꼴에서는 페이지가 스크롤 없는 축약형을 유지하며 상세 다이얼로그 내부 스크롤로 미리보기와 버튼에 접근하는 위젯 테스트가 통과했다. 하드웨어/실기기 조건은 검증하지 않았다.


## Follow-up verification after laptop reconnect — 2026-11-14

- The compact camera control card now opts into a dedicated full-screen route. Other CompactControlSurface callers keep the existing dialog because the new behavior is opt-in. The page keeps the camera owner mounted, rebuilds the controls from its revision notifier, uses a localized BackButton, and keeps the page content in a ListView so large text is scrollable without clipping. The 180 px preview uses contain sizing and has an image semantic label.
- Focused camera/beacon Flutter tests: **29 passed**. Flutter analysis of six affected UI/test files: **No issues found**.
- Two complete passenger-app Flutter runs with JSON reporter both exited 0. Each recorded 793 successful test events, zero failure events, and a successful suite-done event. The earlier interrupted run's single failure counter had no retained test ID or failure detail; the failure did not recur in either complete run, so its original test cannot be attributed from the available log.
- In a task-folder isolated Python environment, installed the declared backend requirements from official PyPI and ran `tests/test_v3_agent_trace.py`: **9 passed** (one Starlette deprecation warning). The regression test confirms that auto fallback trace reports `openai`; no live Gemini request was made. An assertion that read the request-scoped ContextVar outside the TestClient request context was removed; the route trace assertion remains the externally observable check.
- The compact camera UI test covers 360x600 with 2x text: the base page stays compact and scroll-free; its expanded view is an independent page, the preview and controls remain reachable through that page's scroll, and the back control remains visible. Session running state remains true while the page is open and after returning.
- No commits, pushes, merges, deployments, or operational setting changes were made.
