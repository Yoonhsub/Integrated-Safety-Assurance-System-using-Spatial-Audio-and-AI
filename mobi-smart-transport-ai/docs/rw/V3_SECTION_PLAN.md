# V3 Section Plan — 음성 기반 버스 탑승 보조 에이전트

## V3 목표

V3는 사용자가 목적지를 말하면 백엔드 rule engine과 mock/cache/public-data 계층을 통해 버스 탑승 전 과정을 보조하는 시연 가능한 시스템이다.

핵심 흐름:

1. 목적지 기반 탑승 노선/정류장 추천
2. 버스 도착 정보 조회
3. 정류장 도착 이후에만 지오펜싱 대기 범위 감시 활성화
4. 다중 버스 접근 상황에서 타야 할 버스와 잘못된 버스 구분
5. 탑승 실패 시 다음 버스 재안내

## 이번 V3에서 구현한 범위

| 영역 | 상태 | 기준 |
|---|---:|---|
| FastAPI startup / `/health` | 구현 | `backend/api/app/main.py` |
| V3 guidance session/state | 구현 | `/guidance/*` |
| V3 rule fallback agent | 구현 | `/agent/converse` |
| 목적지 추천 | 구현 | `/bus/route-recommend` |
| 도착정보 mock/cache fallback | 구현 | `/bus/arrivals` |
| mock geofence | 구현 | `/mock/geofence` |
| mock beacon decision | 구현 | `/mock/beacons`, `/beacon/decision` |
| missed bus mock event | 구현 | `/mock/bus-event` |
| Flutter V3 화면/API client/debug panel | 구현 | `apps/passenger_app/lib/src/pages/v3_guidance_page.dart` |
| E2E smoke script | 구현 | `scripts/smoke_v3_guidance.py` |

## 2학기로 분리한 범위

아래 항목은 이번 V3 코드에서 구현하지 않는다.

- Qwen/DeepSeek 자체 파인튜닝
- GPU 서버 / vLLM 서빙
- YOLO 기반 비전 인식
- 정류장까지 장애물 회피 안내
- 버스 번호판 인식
- 버스 문 위치 인식
- 실제 버스 비컨 장착 검증
- 실제 정류장 현장 테스트
- HRTF 공간음향 / 헤드트래킹 기반 실시간 3D 오디오

## 안전 판단 원칙

안전 판단은 Gemini나 임의 LLM 응답에 맡기지 않는다. 지오펜싱, 잘못된 버스 접근, 탑승 가능 여부는 백엔드 rule engine이 `state`, `lastDecision`, `cue`로 결정한다.

Flutter는 백엔드 응답의 `cue.type`, `cue.ttsMode`, `shouldVibrate`, `shouldBeep`를 소비한다. `SAFETY_LOCAL` 또는 `LOCAL_TTS`는 로컬 TTS/진동/비프를 우선 사용한다.

## 섹션별 작업 기록

1. Section 1 — 백엔드 import/startup/router/API 계약 안정화
2. Section 2 — 공공버스 API/mock/cache fallback 및 목적지 추천 안정화
3. Section 3 — Agent/Guidance/Geofence/Beacon rule engine 검증
4. Section 4 — Flutter V3 UI/API client/cue/debug panel 정합성 패치
5. Section 5 — smoke script, 문서, 최종 패키징
