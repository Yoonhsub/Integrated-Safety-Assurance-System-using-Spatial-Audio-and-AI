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

## 2026-11-13 접근성·사진 클래스 추가 확인

로그인 화면의 이메일·비밀번호·로그인 버튼은 TalkBack으로 모두 구분되어 읽힌다고 담당자가 보고했다. 수정창·두 번 탭·사용 가능한 작업 등의 안내는 TalkBack 기본 안내다. 로그인 후 홈에 재진입했다. 담당자는 앞선 홈 시험에서 TalkBack과 앱 TTS 겹침이 없었다고 추가 확인했다. 기존 미확인 항목을 이 보고 범위로 보완한다.

목적지 검색은 청주역 및 충북대학교에서 실패했으며 사용자 요청에 따라 FAIL로 기록한다. 원인은 미확정이고 조사는 중지했다.

다음은 노트북의 웹 사진을 휴대폰 카메라로 촬영한 결과다. 신뢰도는 화면의 반올림 표시이며 JSON/프레임별 원본 confidence·bbox를 로그로 수집한 결과는 아니다. 실물·현장 성능이나 정확도 통계가 아니며 소리의 클래스별 3방향 청취는 별도이다.

| 테스트 ID | 장비·환경 | 입력(실측/모의) | 재현 절차 | 기대 결과 | 실제 결과·증빙 | 통과/실패/미실행 | 다음 작업 |
|---|---|---|---|---|---|---|---|
| PHOTO-BUS | main v4·휴대폰 | 노트북 사진 카메라 촬영 | 버스 전체 사진 유지 | bus 박스 | bus 85%, bus-photo-recheck.png | 통과 | 실물·방향음 |
| PHOTO-PM | 동일 | 사진 카메라 촬영 | 킥보드 사진 유지 | parked_pm 박스 | parked_pm 61%, pm-photo-current.png | 통과 | 실물·방향음 |
| PHOTO-POLE | 동일 | 사진 카메라 촬영 | 기둥 사진 유지 | pole 박스 | pole 76%, pole-photo-current.png | 통과 | 실물·방향음 |
| PHOTO-TREE-1 | 동일 | 사진 카메라 촬영 | 첫 나무 사진 유지 | tree_trunk 박스 | 박스·인식 결과 없음, tree-photo-current.png | 실패 | 다른 장면 결과로 덮어쓰지 않음 |
| PHOTO-TREE-2 | 동일 | 다른 사진 카메라 촬영 | 사진을 바꿔 나무줄기 관측 | tree_trunk 박스 | tree_trunk 66%, tree-photo-recheck.png | 통과 | 첫 사진 실패 원인 별도 |
| PHOTO-DOOR | 동일 | 사진 카메라 촬영 | 문이 보이는 버스 사진 유지 | bus_door 박스 | bus_door 89%, door-photo-current.png | 통과 | 문 개방·발밑 안전 판정 아님 |

TFLite 초기화는 기기 로그에서 확인했지만 개별 검출값은 해당 로그에 출력되지 않았다. 위 증빙은 로컬 스크린샷이다. 웹 사진이 포함돼 있으므로 Git에는 결과 문서만 보관한다. 버스 사진 최초 관측에서 버스 문 83%가 표시된 결과(bus-photo-status.png)와 버스 전체 85%는 구분했다.

## 버스 문 방향음 추가 실패 관찰 — 2026-11-13

담당자는 문을 중앙에 둔 채 10초 유지해도 무음이며, 간헐적으로 나오는 음성은 문이 아니라 버스를 안내하는 것 같다고 보고했다. 음향 상세 화면을 직접 열어 최근 요청이 **버스(bus), confidence 0.7567697167396545, LEFT**임을 확인했다. 음향 승인 2·완료 2·재생 중 프레임 제외 46. frameId ab4a7ba7-cc3b-4baf-9025-d5803dc7245b, capturedAt 2026-11-13T03:30:18.270995Z, bbox x=0.0014263885640986352,y=0.33685439825057983,w=0.3057650939083769,h=0.29645586013793945, 중심 x=0.1543089355182871. 증빙 audio-selection-expanded.png는 로컬 보존.

기기 로그에는 12:30:18.831 LEFT cue 시작, 19.921 완료·cleanupErrors 없음, TTS 20.198 시작→28.577 완료가 있다. 이는 해당 버스 안내의 출력 완료 증거이며 버스 문 안내 통과 증거가 아니다.

코드 정책: 적격 검출 중 최고 confidence 하나를 선택하며 문 우선순위는 없다. 문은 bus와 동시 검출·문 면적 70% 이상 bus 내부 겹침, 같은 클래스·방향 3프레임 확인을 요구한다. 동일 의미 반복 억제와 최소 8초 간격이 있다. 따라서 표시 박스와 음향 선택은 다를 수 있다. 다만 이번 중앙 무음의 정확한 탈락 조건을 프레임별로 계측하지 않아 특정 조건 하나로 확정하지 않는다.

판정: PHOTO-DOOR의 **시각 검출** 통과는 유지한다. **문을 음향 대상으로 선택해 중앙 방향음을 내는 시험은 FAIL**로 분리한다. 기존 사진 좌·중앙·우 청취 관찰을 모든 클래스의 통과로 확대하지 않는다. 수정·재빌드 없이 실패와 원인 후보만 기록했다.

## 장애물 클래스별 방향음 청취 — 2026-11-13 후속

입력은 노트북 사진을 휴대폰 카메라로 촬영한 실측 추론, 출력은 실제 Shokz 이어폰이며 머리 회전은 사용하지 않았다. 담당자가 객체 박스를 좌·중앙·우로 옮겨 각 위치에서 안내 후에도 약 10초 유지하는 절차를 수행했다. 아래 청취 결과는 담당자 보고로 확인했으며 각 단계의 프레임 JSON·음향 파형은 수집하지 않았다.

| 테스트 ID | 장비·환경 | 입력(실측/모의) | 재현 절차 | 기대 결과 | 실제 결과·증빙 | 통과/실패/미실행 | 다음 작업 |
|---|---|---|---|---|---|---|---|
| AUDIO-PM-LCR | main v4·Shokz | 사진 화면 카메라 촬영 | 킥보드 박스를 좌→중앙→우로 이동 | 위치와 방향음 일치 | 담당자 왼쪽 들림, 중앙 음성 가운데 및 양쪽 비슷, 오른쪽 들림 | 통과 | 실물 현장 검증과 구분 |
| AUDIO-POLE-LCR | 동일 | 사진 화면 카메라 촬영 | 기둥 박스를 좌→중앙→우로 이동 | 위치와 방향음 일치 | 담당자 왼쪽 들림, 중앙 양쪽 비슷, 오른쪽도 성공 보고 | 통과 | 실물 현장 검증과 구분 |
| AUDIO-TREE-LCR | 동일 | 검출된 다른 나무 사진 카메라 촬영 | 나무줄기 박스를 좌→중앙→우로 이동 | 위치와 방향음 일치 | 담당자 전부 성공 보고 | 통과 | 최초 나무 사진 미검출 실패는 별도 유지 |

버스 문 중앙 방향음 실패는 해결되지 않았으며 위 장애물 세 종류의 성공으로 덮어쓰지 않는다. 버스 클래스 전체 3방향 청취와 실제 현장 검증은 아직 별도 미확인이다. 앱 코드 변경·재빌드 없음.

## 2026-11-13 격리 Android 카메라 Backend 후속 검증

main 소스 변경 없이 기존 `lib/local_android_camera_backend_main.dart`를 별도 패키지 `.localvision`으로 빌드·설치했다. 기존 Firebase 로그인 앱은 보존했다. Backend는 단일 프로세스 fake-auth/memory 환경이며 실제 Firebase 영속 저장 검증이 아니다.

| 테스트 ID | 장비·환경 | 입력(실측/모의) | 재현 절차 | 기대 결과 | 실제 결과·증빙 | 통과/실패/미실행 | 다음 작업 |
|---|---|---|---|---|---|---|---|
| ISO-CAM-01 | SM-S942N Android 17, 별도 localvision APK, PC 격리 Backend | 카메라·TFLite 실측 / 노트북 사진 / 인증·저장소 모의 | 연결 파일 선택 → 세션 생성 → PC binding 승인 → v4 모델 선택 → 사진 촬영 | 실제 추론 결과 POST 202 | 307개 요청 202, frameId 307개 고유. 탐지 포함 10프레임. 사용자 박스 표시 확인. bus_door confidence 0.7897480130195618, 정규화 bbox 보존된 서버 preview 기록 확인 | PASS(격리 수신 범위) | 실제 Firebase 영속화는 별도 |
| ISO-CAM-02 | 동일 | 실측 프레임 / 격리 서버 | 앱의 일반·proofOnly observation 조회 | 정상 조회 및 안내 판정과 분리 | 앱 observation GET 200 84회 이상, 화면 서버 관찰 표시 확인. 클라이언트 소스는 일반 조회 후 proofOnly 조회를 수행한다. query/응답 본문 전체와 원본 송신 payload 대조는 별도 수집하지 못함. PC 수동 요청 2회는 lease 헤더 누락으로 403이므로 앱 실패로 집계하지 않음 | PASS(앱 조회), 나머지 미실행 | 응답 원문 및 guidanceEligible=false 실측 증빙 추가 |
| ISO-CAM-03 | 격리 Backend | 실측 전송 / 중복 재전송 미실행 | 동일 event 재전송 및 Ledger 대조 | 중복 생성 없음 | 실기기 동일 이벤트 재전송·Ledger 원문 대조는 미실행. 기존 자동 테스트 190개 통과와 구분 | 미실행 | 동일 payload 재전송 증빙 수집 |
| ISO-CAM-04 | 격리 Backend | 종료 처리 실측 | 세션 종료 → 서버 종료 → reverse·임시 연결 파일 제거 | 일반 안내·안전 이벤트 발생 없음 | 종료 result: safetyCreate=0, publish=0, safetyItems=0, stopped=true, singleWorkerMemoryOnly=true. 임시 폰 연결 파일 및 소유 reverse 제거 | PASS | 없음 |
| PHOTO-BUS-MIX | 기존 main 앱·이어폰 | 휴대폰 카메라 실측 / 노트북 버스 사진 | 사진을 좌·중앙·우로 이동 | 방향 일치, 대상 명칭 안정적 | 사용자 방향 전부 성공 보고. 대상은 bus/bus_door로 번갈아 표시됨 | 방향 PASS / 대상 안정성 FAIL | 기존 무음 사례와 함께 선택 정책 후속 점검 |

증빙은 PC `outputs/isolated-camera-20261113-124151/`의 trace.jsonl, verification-summary.json, camera-ui.xml, control/result.json에 보관했다. 단기 자격 파일과 APK는 Git에 포함하지 않는다. 전체 Backend 완료로 집계하지 않는다.

### 격리 Backend 기록 재생 보완 검증

| 테스트 ID | 장비·환경 | 입력(실측/모의) | 재현 절차 | 기대 결과 | 실제 결과·증빙 | 통과/실패/미실행 | 다음 작업 |
|---|---|---|---|---|---|---|---|
| ISO-REC-DUP-01 | 기존 main FastAPI TestClient, fake auth/memory | 직전 Android 실측 탐지 기록 재생 + 새 테스트 세션·시각·모델 메타데이터 구성 | 같은 payload 2회 전송 → Ledger 전후 비교 → 일반/proofOnly 조회 → 같은 eventId의 confidence 변경 재전송 | 동일 receipt, Ledger 1개, 원본 탐지 보존, 충돌 거부 | pytest 1 passed(2.12초). 두 전송 202와 receipt 완전 동일, Ledger 이벤트 1개 및 전체 데이터 불변. 일반/proofOnly 각각 200, frameId/class/confidence/bbox 동일, guidanceEligible=false, proofOnly observations=[] 및 bindings 일치. 변경 payload 409, Ledger 불변. outputs/isolated-camera-20261113-124151/recorded-duplicate-evidence.json | PASS(기록 재생·격리 저장소 범위) | 휴대폰 실제 송신 원문 그대로의 재전송 및 실제 Firebase 영속 저장 검증은 미실행 |

이 검증은 main 소스를 수정하지 않고 작업 폴더 outputs의 임시 테스트에서 기존 인증 경계 fixture와 API를 재사용했다. 실제 휴대폰 원문을 가로채 재전송한 검증과 구분한다. 이전 ISO-CAM-03의 실기기 원문 재전송 미실행 상태는 유지한다.
