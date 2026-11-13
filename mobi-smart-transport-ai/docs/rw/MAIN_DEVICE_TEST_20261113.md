# main 644d199 실기기 점검 진행 결과

환경: SM-S942N Android 17, Firebase 공개 Android 설정 포함 main APK. 입력·청취 결과는 담당자 보고이며 정밀 음향 지연은 미계측. ajh_test 결과와 별도이다.

| 테스트 ID | 장비·환경 | 입력(실측/모의) | 재현 절차 | 기대 결과 | 실제 결과·증빙 | 통과/실패/미실행 | 다음 작업 |
|---|---|---|---|---|---|---|---|
| LOGIN | main·휴대폰 | Firebase 실제 계정 | 담당자 직접 로그인 | 홈 진입 | 담당자 로그인 완료 | 통과 | 보호 API는 별도 |
| HOME-TTS | TalkBack OFF | 실제 터치 | 첫 탭·빠른 재탭·1초 후 재탭·다른 버튼 선택 | 설명·화면 열기·설명 재시작·음성 전환 | 각각 설명만·열림·설명 다시·바뀜 보고 | 통과 | 반복 조작 편의성 별도 |
| TALKBACK | TalkBack ON | 실제 접근성 조작 | 두 기능·헤드폰·카메라 시작/중지 | 기본 더블탭 동작 | 모두 열림·영상 보임·중지 보고. 로그인 화면 및 음성 겹침은 미확인 | 통과 | 미확인 범위 유지 |
| CAMERA-PHOTO | Shokz·v4 | 노트북 사진을 실제 카메라로 촬영 | 객체 좌·중앙·우→카메라 중지→화면 이탈 | 방향음 일치·잔류 출력 없음 | 박스 표시, 왼쪽·비슷·오른쪽, 두 종료 모두 멈춤 보고 | 통과 | 실제 현장 장애물과 구분; 클래스별 전체 검증 아님 |
| BLE-A-LOSS | A/B·WT901·Shokz | BLE 실측 | B OFF 후 A 단일음→A OFF→ON→수동 시작 | 신호 상실 중지·수동 복구 | B OFF 때도 재생 종료 관찰. A만으로 단일음, A OFF 멈춤, 복구 자동 없음, 수동 들림 | 통과 | B 전환 원인·정밀 수신 시각 별도 |
| SENSOR-LOSS | WT901·A·Shokz | 센서 전원 실측 | 새 5분 스캔·단일음 확인 직후 센서 OFF→재연결→기준·수동 시작 | 입력 상실 중지·명시적 복구 | 재시험 멈춤, 자동 없음, 수동 들림. 첫 시도는 스캔 만료 가능성 있어 판정에서 제외 | 통과 | 실제 머리 장착 회전은 미실행 |
| HEADPHONE-LOSS | Shokz·A·WT901 | 실제 출력 연결 | 단일음 중 이어폰 OFF→ON→수동 시작 | 상실 후 중지·명시적 복구 | 멈춤, 자동 없음, 수동 들림 보고 | 통과 | 단절 후 새 경고의 스피커 유출 차단은 아직 미검증 |
| HIGH-RISK-PRIORITY | 현재 main | 장애물 모의 예정 | 고위험→비콘 상실→해제→새 목표 | 경고 우선·최신 목표 후 재개 | 현재 진행한 비콘/센서 단절 시험으로는 증명하지 않음. 진단 화면의 B 경고와 위험 해제 상태기계는 구분 | 미실행 | 현재 main의 주입 경로 확인 필요 |
| ONLINE-BACKEND | 실제 서버 | 채팅·STT·카메라 전송 예정 | 답변·Ledger·Observation 조회 | 실제 응답·중복 방지·guidanceEligible=false | 아직 실행하지 않음 | 미실행 | 온라인 기능 시험 |

본 문서는 로컬 진행 기록이며 main 소스나 PR을 수정하지 않았다. 테스트별 통과는 표의 관찰 범위에 한정하며 전체 실제 탑승 안내 통과를 의미하지 않는다.

## 2026-11-13 격리 Backend 사전 검증

- main 644d199 소스·설치 APK를 유지했다. 운영 Firebase·Cloud Run 설정이나 계정은 변경하지 않았다.
- 기존 run_android_local_backend.py의 명시적 Fake 인증·메모리 저장소·외부 연결 차단 self-test를 실행했다. 15개 HTTP 확인 통과, androidRuntime=false, safetyEventsCreated=0. 시험 서버는 도구 종료 시 정리되었다.
- backend/api의 test_vision_event_ledger.py 및 test_vision_v2.py: 190 passed, 1 warning, 5.89초. Ledger 원자성·중복·관측 만료·proof lifecycle·Android v4 관측 보존 등 기존 자동 테스트 범위이다.
- 증빙: isolated-backend-selftest.jsonl. 실제 휴대폰 카메라의 POST 202→Ledger→Observation 일반/proofOnly를 실측으로 확인한 결과가 아니다.
- 현재 설치 앱은 공개 설정의 Cloud Run HTTPS 주소로 고정되어 있다. 이 APK를 유지한 상태에서 PC 격리 Backend로 경로를 바꾸는 런타임 설정은 확인되지 않았다. 따라서 휴대폰 격리 전송 시험은 미실행이다. 후속 실행에는 격리용 별도 APK 또는 별도 주소로 빌드한 앱과 해당 인증·Binding 준비가 필요하다.
- 고위험 선점: main 라우트는 HardwareBusPage()에 obstacle snapshot을 주입하지 않는다. 청취 확인 패널은 busEnabled=false인 독립 danger cue이며 탑승 안내 선점·위험 해제 후 새 목표 재개 검증으로 확대하지 않는다.
- 목적지 검색: 청주역 및 충북대학교 검색 실패, 원인 미확정; 사용자 요청으로 조사 보류.
- 음성 입력: 담당자 실제 발화가 표시되고 서버 답변이 화면 및 한국어 음성으로 제공됨을 보고받았다. 목적지 검색이나 TAGO 실데이터 성공을 뜻하지 않는다.
