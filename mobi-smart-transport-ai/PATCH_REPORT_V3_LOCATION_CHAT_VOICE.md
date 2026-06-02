# V3 위치·대화맥락·음성 UX 패치 보고

## 수정 요약

1. HTTP 웹 데모에서 브라우저 위치 권한을 사용할 수 없을 때 V3 경로 계산이 멈추지 않도록, 웹 데모 기준 위치 fallback을 기본 활성화했습니다.
2. `/agent/converse`가 세션에 이미 선택된 경로를 기억하고, “무슨 경로?”, “어디서 타?”, “왜 추천?” 같은 짧은 후속 질문에 현재 경로 맥락으로 답하도록 보강했습니다.
3. 홈 화면의 `음성으로 목적지 입력`, `현재 상태 음성 안내` 버튼에서 부자연스러운 로컬 Flutter TTS를 제거했습니다.
4. 음성 인식이 끝난 뒤 인식된 목적지를 자동으로 V3 에이전트에 전달하고, 가능하면 Gemini TTS 음성으로 결과를 재생하도록 연결했습니다.
5. Gemini TTS가 실패하거나 quota/키 문제로 사용할 수 없을 때는 로컬 TTS로 억지 재생하지 않고 효과음으로 fallback합니다.

## 주요 수정 파일

- `apps/passenger_app/lib/src/pages/home_page.dart`
- `apps/passenger_app/lib/src/pages/v3_guidance_page.dart`
- `apps/passenger_app/lib/src/services/audio_haptic_cue_service.dart`
- `apps/passenger_app/lib/src/services/voice_guide_service.dart`
- `backend/api/app/api/routes/v3_agent.py`
- `backend/api/app/services/v3_guidance_store.py`
- `backend/api/app/services/v3_gemini_service.py`
- `backend/api/tests/test_v3_section3_route_plan_agent.py`

## 검증 결과

- `python -m pytest -q -p no:cacheprovider`: 127 passed
- `python -m unittest discover -s tests -v`: 30 tests OK
- `python -m compileall -q app ../../services/public_data/public_data_client`: 통과
- `python scripts/smoke_backend_integration.py`: PASS
- Uvicorn 임시 실행 후 `V3_API_BASE_URL=http://127.0.0.1:8001 python scripts/smoke_v3_guidance.py`: 14단계 PASS

## 실행하지 못한 검증

- `flutter analyze`, `flutter test`: 현재 작업 환경에 Flutter/Dart SDK가 없어 실행하지 못했습니다.
- 실제 iOS Safari/KakaoTalk 브라우저 음성 재생: 브라우저 권한과 사용자 gesture 정책이 실제 기기에서 추가 확인 필요합니다.
