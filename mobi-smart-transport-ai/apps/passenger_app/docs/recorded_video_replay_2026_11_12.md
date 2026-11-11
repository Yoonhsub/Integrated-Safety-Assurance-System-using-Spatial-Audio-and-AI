# 기록 영상 재생 준비 — 2026-11-12

입력은 담당자가 제공한 KakaoTalk_20261111_142314874.mp4이며 원본을 수정하거나 GitHub에 업로드하지 않았다. 1080×2340, 30fps, 1,234프레임, 41.133초. SHA-256: `5231af7ec9f314ae8c7b971c1a6cb1cb0d232cfc4d7f440ca582959a0f6b42ac`.

영상은 원본 카메라 스트림이 아닌 앱 화면 녹화다. 카메라 장면에 기존 탐지 박스·라벨이 포함되어 있으므로 독립적인 원본 영상 평가로 간주하지 않는다. 화면 미리보기 영역 x=48..1032, y=366..1845를 잘라 기존 unified v4 PT 모델로 CPU 재추론했다. 모델은 Android TFLite와 같은 v4 계열이지만 실행 형식·전처리 경로가 달라 수치 일치를 주장하지 않는다.

| 테스트 ID | 장비·환경 | 입력(실측/모의) | 재현 절차 | 기대 결과 | 실제 결과·증빙 | 통과/실패/미실행 | 다음 작업 |
|---|---|---|---|---|---|---|---|
| RECORD-INFER | PC CPU·unified v4 PT | 기록 재생 | 8/12/15/18/22초 카메라 영역 재추론 | 실제 모델 탐지 JSON 생성 | 15초 tree_trunk 0.615532, bbox 중심 x 약 0.058 → 왼쪽. 앱 클래스 기준 0.55 이상. frame-15s.json·annotated.jpg | 통과 | 앱 재생·청취 |
| RECORD-OTHER | 동일 | 기록 재생 | 같은 다섯 프레임 비교 | 결과를 숨기지 않고 기록 | 8초 tree_trunk 0.522761은 앱 기준 미달. 12/18/22초 검출 없음. 빈 검출을 실제 경로 안전으로 해석하지 않음 | 통과 | 원본 영상 확보 시 재평가 |
| RECORD-AUDIO | Android·골전도 이어폰 | 탐지 기록 재생 / 위험도 모의 caution | AI 탐지 JSON 한 프레임 재생에 replay-left-tree.json 입력 | 왼쪽 주의 cue, 2초 후 관측 만료 | 아직 휴대폰 입력·재생·청취하지 않음 | 미실행 | 새 시연 세션에서 실행 |

기존 DoorVisionReplay는 source·capturedAt을 표시하고 bbox 중심의 화면 3분할로 방향을 구한다. source는 recorded_screen_video, capturedAt은 video_offset_seconds:15로 기록하여 현재 실시간 카메라로 위장하지 않는다. 위험도는 모델이 산출한 충돌 위험이 아니라 담당자가 선택하는 모의 caution이다. 앱의 카메라 실측 경로(DoorVisionPolicy)에 이 JSON을 넣지 않는다.

실행: workspace의 work/recorded-vision-env/Scripts/python.exe로 work/analyze_recorded_video.py 실행. 격리 환경에 설치했으며 기존 앱 의존성은 수정하지 않았다. 추론 결과 JSON·박스 이미지·환경 버전을 로컬 증빙 ZIP에 보존한다. 원본 영상·파생 이미지는 GitHub에 올리지 않는다. 실제 지원 장애물 카메라 시험과 실제 안전 판정은 여전히 미실행이다.
