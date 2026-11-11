# 기록 영상 재생 준비 — 2026-11-12

입력은 담당자가 제공한 KakaoTalk_20261111_142314874.mp4이며 원본을 수정하거나 GitHub에 업로드하지 않았다. 1080×2340, 30fps, 1,234프레임, 41.133초. SHA-256: `5231af7ec9f314ae8c7b971c1a6cb1cb0d232cfc4d7f440ca582959a0f6b42ac`.

영상은 원본 카메라 스트림이 아닌 앱 화면 녹화다. 카메라 장면에 기존 탐지 박스·라벨이 포함되어 있으므로 독립적인 원본 영상 평가로 간주하지 않는다. 화면 미리보기 영역 x=48..1032, y=366..1845를 잘라 기존 unified v4 PT 모델로 CPU 재추론했다. 모델은 Android TFLite와 같은 v4 계열이지만 실행 형식·전처리 경로가 달라 수치 일치를 주장하지 않는다.

| 테스트 ID | 장비·환경 | 입력(실측/모의) | 재현 절차 | 기대 결과 | 실제 결과·증빙 | 통과/실패/미실행 | 다음 작업 |
|---|---|---|---|---|---|---|---|
| RECORD-INFER | PC CPU·unified v4 PT | 기록 재생 | 8/12/15/18/22초 카메라 영역 재추론 | 실제 모델 탐지 JSON 생성 | 15초 tree_trunk 0.615532, bbox 중심 x 약 0.058 → 왼쪽. 앱 클래스 기준 0.55 이상. frame-15s.json·annotated.jpg | 통과 | 앱 재생·청취 |
| RECORD-OTHER | 동일 | 기록 재생 | 같은 다섯 프레임 비교 | 결과를 숨기지 않고 기록 | 8초 tree_trunk 0.522761은 앱 기준 미달. 12/18/22초 검출 없음. 빈 검출을 실제 경로 안전으로 해석하지 않음 | 통과 | 원본 영상 확보 시 재평가 |
| RECORD-AUDIO | Android·골전도 이어폰 | 탐지 기록 재생 / 위험도 모의 caution | AI 탐지 JSON 한 프레임 재생에 replay-left-tree.json 입력 | 왼쪽 주의 cue, 2초 후 관측 만료 | 01:22:13.238 warning·tree_trunk#0, LEFT 13.354→14.252 완료·cleanupErrors 없음. 담당자 실제 이어폰 왼쪽 청취 | 통과 | 기록 입력 포함 최종 리허설 |

기존 DoorVisionReplay는 source·capturedAt을 표시하고 bbox 중심의 화면 3분할로 방향을 구한다. source는 recorded_screen_video, capturedAt은 null(실제 촬영 시각 미상), videoOffsetSeconds는 15로 기록하여 현재 실시간 카메라로 위장하지 않는다. 위험도는 모델이 산출한 충돌 위험이 아니라 담당자가 선택하는 모의 caution이다. 앱의 카메라 실측 경로(DoorVisionPolicy)에 이 JSON을 넣지 않는다.

실행: workspace의 work/recorded-vision-env/Scripts/python.exe로 work/analyze_recorded_video.py 실행. 격리 환경에 설치했으며 기존 앱 의존성은 수정하지 않았다. 추론 결과 JSON·박스 이미지·환경 버전을 로컬 증빙 ZIP에 보존한다. 원본 영상·파생 이미지는 GitHub에 올리지 않는다. 실제 지원 장애물 카메라 시험과 실제 안전 판정은 여전히 미실행이다.

## 휴대폰 기록 재생 실측 결과

설치된 검증 APK f2fe3ac, SM-S942N Android 17, 실제 BLE 스캔과 이어폰 연결을 사용했다. 실시간 카메라와 일반 모의 스냅샷 스위치는 OFF, 화면의 모의 방향 선택은 중앙으로 유지했다. 따라서 LEFT는 일반 방향 메뉴가 아니라 기록 탐지 bbox에서 나온 값이다. 위험도만 명시적으로 모의 caution을 선택했다.

초기 준비 JSON은 video_offset_seconds:15 문자열을 capturedAt에 넣어 DateTime 계약을 위반했다. 01:19:54.006 입력 거부·stopped가 발생했고 재생되지 않았다. 생성 스크립트와 JSON을 capturedAt=null·videoOffsetSeconds=15로 수정했으며 앱 코드의 유효성 검사를 우회하지 않았다.

수정 후 01:20:56.652 warning, LEFT cue 56.753→57.433 완료, 58.664 관측 만료로 unavailable을 기록했다. 담당자가 재청취를 요청하여 같은 프레임을 다시 재생했다. 01:22:13.238 warning, LEFT 13.354→14.252 완료 후 담당자는 **왼쪽**이라고 답했다. 01:22:15.240 관측 만료로 unavailable: 약 2.002초 뒤 재확인 상태로 전환했다. 마지막 프레임을 계속 유효한 것으로 취급하지 않았다. 출력 로그와 실제 청취 보고를 각각 보존하며 음향 파형·지연은 측정하지 않았다.

증빙: phone-replay-accepted.png, phone-device-evidence.log, replay-left-tree.json. 재생 JSON을 저장소 docs/fixtures/recorded-left-tree.json에도 보관했다. 최초 입력 오류와 화면 재진입 과정도 원본 로그에 남겼다. 01:22:32.662 홈 이동·ACTIVITY_PAUSE·activeTracks=0 확인, 로그 수집 종료. 기능 코드 변경이나 새 APK 빌드는 없다.

이는 한 프레임의 기록 재생 통과다. 영상 전체 자동 재생, 오른쪽 실물 탐지, 실시간 카메라 탐지, 실제 충돌 위험·거리·문 안전·자동 탑승은 검증하지 않았다. 화면에 남은 기존 탐지 오버레이의 영향도 배제하지 못했다.
