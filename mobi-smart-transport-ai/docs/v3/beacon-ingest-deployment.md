# V3 Beacon Ingest API — VM 배포 운영 가이드

본 문서는 V3 Beacon Ingest API(Issue #35)의 VM 배포·검증·롤백 절차를 정리한 운영 가이드다. 다른 팀원이 V3 beacon 관련 후속 작업 시 본 문서의 절차를 따른다.

관련 이슈: #35  
관련 PR: #45 (초기 머지)

## 0. 개요

### 본 API의 endpoint 3개

| 메서드 | 경로 | 역할 |
|---|---|---|
| POST | /api/v3/beacon/ingest | 단일 RSSI 이벤트 수신 + 판정 반환 |
| GET | /api/v3/beacon/latest | 최신 판정 상태 조회 (lost timeout 자동 체크) |
| POST | /api/v3/beacon/reset | 세션 초기화 (데모용) |

### 호출자

- Android BLE bridge (실제 비컨 스캐너)
- 수동 curl (개발/검증)
- PWA polling (passenger_app에서 latest 조회)

### 본 API의 위치

| 분류 | 파일 |
|---|---|
| 라우터 | `backend/api/app/api/routes/v3_beacon_ingest.py` |
| 서비스 | `backend/api/app/services/v3_beacon_service.py` |
| 스키마 | `backend/api/app/schemas/v3.py` (BeaconIngestRequest, BeaconIngestResponse 등) |
| main.py 등록 | `backend/api/app/main.py` line 21, line 138 |
| 테스트 | `backend/api/tests/test_v3_beacon_ingest.py` |

## 1. 사전 준비

### 1.1 VM 접속 권한 확인

본인 Google 계정에 다음 권한이 필요하다:

- `compute.instances.get` (VM 접근)
- `iam.serviceAccountUser` (SSH 키 발급)

권한 없으면 프로젝트 owner에게 IAM 권한 부여 요청한다.

### 1.2 gcloud CLI 인증 확인

```bash
gcloud auth list
gcloud config list
```

기대 출력:
- `account`: 본인 Google 계정
- `project`: gen-lang-client-0309873247

### 1.3 VM 접속 테스트

```bash
gcloud compute ssh instance-20260330-105638 \
  --project=gen-lang-client-0309873247 \
  --zone=us-central1-b \
  --quiet
```

`doseo@instance-...` 또는 `sst70@instance-...` 프롬프트 뜨면 성공. `exit`로 빠져나온다.

## 2. fresh clone 규칙

stale 로컬 디렉토리에서 배포하지 않는다. 작업 시작 전 main 최신 상태를 확인한다.

```bash
cd /tmp
rm -rf mobi-work
gh repo clone Yoonhsub/Integrated-Safety-Assurance-System-using-Spatial-Audio-and-AI mobi-work -- --branch main --single-branch
cd mobi-work/mobi-smart-transport-ai
git checkout -b feature/<issue-name>
```

또는 본인 기존 작업 디렉토리에서:

```bash
git checkout main
git pull origin main
git checkout -b feature/<issue-name>
```

## 3. 배포 충돌 방지 규칙

공통 백엔드 서비스(`mobi-backend.service`)를 한 명이 재시작하면 다른 사람의 검증이 깨질 수 있다. 다음 규칙을 따른다.

### 3.1 배포 시작 알림 (필수)

배포 전 단톡 또는 이슈 댓글로 다음 형식 알림:

[VM 배포 시작]
담당: <본인 이름>
이슈: #XX
배포 범위: backend / frontend / both
검증 예정 기기: <기기>
예상 검증 항목: <endpoint 등>

### 3.2 배포 완료 알림 (필수)

배포 후 다음 형식 알림:
[VM 배포 완료]
담당: <본인 이름>
이슈: #XX
검증 URL: https://mobi.35.232.72.197.nip.io/...
검증 결과: <PASS / FAIL>
남은 문제: <있다면>

### 3.3 동시 배포 금지

배포 시작 알림 후 완료 알림이 올라오기 전까지 다른 팀원은 VM 손대지 않는다.

## 4. 백엔드 파일 scp/install 절차

### 4.1 로컬에서 파일 업로드

수정한 파일을 VM `/tmp/`로 업로드한다. 예시 (V3 beacon ingest 작업 시):

```bash
gcloud compute scp backend/api/app/schemas/v3.py \
  instance-20260330-105638:/tmp/v3-schema.py \
  --project=gen-lang-client-0309873247 \
  --zone=us-central1-b --quiet

gcloud compute scp backend/api/app/services/v3_beacon_service.py \
  instance-20260330-105638:/tmp/v3_beacon_service.py \
  --project=gen-lang-client-0309873247 \
  --zone=us-central1-b --quiet

gcloud compute scp backend/api/app/api/routes/v3_beacon_ingest.py \
  instance-20260330-105638:/tmp/v3_beacon_ingest.py \
  --project=gen-lang-client-0309873247 \
  --zone=us-central1-b --quiet

gcloud compute scp backend/api/app/main.py \
  instance-20260330-105638:/tmp/main.py \
  --project=gen-lang-client-0309873247 \
  --zone=us-central1-b --quiet
```

### 4.2 VM 안에서 백업 + install

VM 접속 후:

```bash
ROOT=/home/sst70/mobi-deploy/mobi-smart-transport-ai
TS=$(date -u +%Y%m%dT%H%M%SZ)

# 백업 디렉토리 (이미 존재해도 무해)
sudo mkdir -p /home/sst70/mobi-deploy/backups

# 수정 대상 파일 백업 (신규 파일은 백업 불필요)
sudo cp $ROOT/backend/api/app/schemas/v3.py /home/sst70/mobi-deploy/backups/v3-schema-before-$TS.py
sudo cp $ROOT/backend/api/app/main.py /home/sst70/mobi-deploy/backups/main-before-$TS.py

# 새 파일 설치
sudo install -o sst70 -g sst70 -m 0644 /tmp/v3-schema.py $ROOT/backend/api/app/schemas/v3.py
sudo install -o sst70 -g sst70 -m 0644 /tmp/v3_beacon_service.py $ROOT/backend/api/app/services/v3_beacon_service.py
sudo install -o sst70 -g sst70 -m 0644 /tmp/v3_beacon_ingest.py $ROOT/backend/api/app/api/routes/v3_beacon_ingest.py
sudo install -o sst70 -g sst70 -m 0644 /tmp/main.py $ROOT/backend/api/app/main.py
```

### 4.3 컴파일 검증

```bash
sudo -u sst70 bash -lc "cd $ROOT && .venv/bin/python -m compileall -q backend/api/app"
```

에러 메시지 없으면 문법 OK. 에러 발견 시 즉시 롤백(§7) 후 코드 수정.

## 5. systemctl restart와 health check

### 5.1 백엔드 재시작

```bash
sudo systemctl restart mobi-backend.service
```

### 5.2 활성 상태 확인

```bash
sudo systemctl is-active mobi-backend.service
```

기대 출력: `active`

만약 `failed` 또는 `activating` 출력 시 즉시 로그 확인:

```bash
sudo journalctl -u mobi-backend.service -n 50 --no-pager
```

문제 해결 안 되면 롤백(§7) 진행.

### 5.3 헬스체크

```bash
curl -s http://localhost:8000/health
```

기대 응답 (JSON):
```json
{"status":"ok","service":"mobi-backend-api",...}
```

`status: ok` 확인되면 정상 기동.

## 6. 환경변수 확인 (값 출력 금지)

V3 beacon 관련 threshold 환경변수:

| 변수 | 기본값 | 의미 |
|---|---|---|
| BEACON_RSSI_NEAR | -62 | NEAR 판정 RSSI 기준 |
| BEACON_RSSI_MID | -75 | MID 판정 RSSI 기준 |
| BEACON_LOST_TIMEOUT | 5 | LOST 자동 전환 타임아웃 (초) |
| BEACON_UNSTABLE_DELTA | 20 | SIGNAL_UNSTABLE 감지 RSSI 변화량 |

### 6.1 환경변수 존재 여부만 확인 (값 출력 금지)

```bash
# 값을 출력하지 않고 존재 여부만 확인
[ -n "$BEACON_RSSI_NEAR" ] && echo "BEACON_RSSI_NEAR: set" || echo "BEACON_RSSI_NEAR: default"
[ -n "$BEACON_LOST_TIMEOUT" ] && echo "BEACON_LOST_TIMEOUT: set" || echo "BEACON_LOST_TIMEOUT: default"
```

### 6.2 threshold 조정이 필요한 경우

VM의 `.env` 또는 systemd 서비스 정의에 환경변수 추가 후 재시작. 자세한 내용은 VM 운영자(@sst70)와 협의.

## 7. 롤백 절차

배포 후 문제 발생 시 즉시 이전 상태로 복원한다.

### 7.1 백업에서 복원

```bash
ROOT=/home/sst70/mobi-deploy/mobi-smart-transport-ai
# TS는 배포 시 사용한 그 값

# 수정된 파일 복원
sudo cp /home/sst70/mobi-deploy/backups/v3-schema-before-$TS.py $ROOT/backend/api/app/schemas/v3.py
sudo cp /home/sst70/mobi-deploy/backups/main-before-$TS.py $ROOT/backend/api/app/main.py

# 신규 파일 제거 (이전엔 없었던 파일)
sudo rm -f $ROOT/backend/api/app/services/v3_beacon_service.py
sudo rm -f $ROOT/backend/api/app/api/routes/v3_beacon_ingest.py

# 재시작
sudo systemctl restart mobi-backend.service
sudo systemctl is-active mobi-backend.service
curl -s http://localhost:8000/health
```

### 7.2 롤백 후 알림

[롤백 진행]
담당:
이슈: #XX
원인: <간단히>
복원 시각: <UTC 시각>
복원 상태: <PASS / FAIL>
다음 조치: <분석 + 재시도 계획>

## 8. 검증 절차

### 8.1 수동 curl 검증 (필수)

배포 후 외부에서 curl로 다음 시나리오 검증.

#### Test 1: target NEAR

```bash
curl -X POST https://mobi.35.232.72.197.nip.io/api/v3/beacon/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "sessionId": "vm-verify",
    "deviceId": "manual-test",
    "beaconId": "MOBI_BUS_502_TARGET",
    "busId": "BUS_502_NOW",
    "routeNo": "502",
    "rssi": -55,
    "distanceMeters": 2.0,
    "source": "MANUAL_TEST",
    "timestamp": "<현재 UTC ISO 시각>"
  }'
```

기대: `decision: TARGET_BUS_NEAR`, `phase: BOARDING_CONFIRMATION`.

#### Test 2: GET /latest (즉시 조회)

```bash
curl https://mobi.35.232.72.197.nip.io/api/v3/beacon/latest?sessionId=vm-verify
```

기대: Test 1 응답과 동일. **5초 안에 호출해야** LOST 자동 전환되지 않음.

#### Test 3: wrong NEAR

```bash
curl -X POST https://mobi.35.232.72.197.nip.io/api/v3/beacon/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "sessionId": "vm-verify",
    "deviceId": "manual-test",
    "beaconId": "MOBI_BUS_100_WRONG",
    "rssi": -58,
    "distanceMeters": 3.0,
    "source": "MANUAL_TEST",
    "timestamp": "<현재 UTC ISO 시각>"
  }'
```

기대: `decision: WRONG_BUS_NEAR`, `cueType: WRONG_BUS_NEAR`.

#### Test 4: LOST 자동 전환

```bash
# 6초 이상 대기 후
sleep 6
curl https://mobi.35.232.72.197.nip.io/api/v3/beacon/latest?sessionId=vm-verify
```

기대: `decision: BEACON_LOST`, `proximity: LOST`, `warnings: ["No beacon signal for over 5 seconds"]`.

#### Test 5: reset

```bash
curl -X POST https://mobi.35.232.72.197.nip.io/api/v3/beacon/reset?sessionId=vm-verify
```

기대: `{ "sessionId": "vm-verify", "status": "reset" }`.

### 8.2 회귀 확인

기존 endpoint 동작 영향 없는지 확인:

```bash
# 기존 V3 beacon endpoint
curl https://mobi.35.232.72.197.nip.io/beacon/decision?sessionId=demo-session

# 기존 mock beacons endpoint
curl -X POST https://mobi.35.232.72.197.nip.io/mock/beacons \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"demo","beacons":[]}'
```

두 endpoint 모두 정상 응답이어야 함.

## 9. AJH 하드웨어 테스트 지원 (#36 연계)

본 API는 @ajh1206의 하드웨어 비컨 테스트에서 호출된다. 자세한 사용법은 별도 가이드 참조:

- `docs/v3/beacon-api-guide-for-ajh.md` (API 사용법, threshold 조정, 로그 확인)

### 9.1 로그 확인

AJH 테스트 중 본인 API 호출이 정상 처리됐는지 VM 로그로 확인:

```bash
sudo journalctl -u mobi-backend.service -f
# 또는 최근 50줄
sudo journalctl -u mobi-backend.service -n 50 --no-pager
```

## 10. 한계 사항 및 주의

- **in-memory 저장**: 백엔드 재시작 시 모든 세션 상태가 초기화된다. 데모 스코프로 충분하나 영구 저장이 필요하면 Firebase RTDB로 확장 필요.
- **단일 워커 전제**: 현재 uvicorn 단일 워커 구성. 멀티워커 전환 시 메모리 dict가 워커 간 공유되지 않음.
- **threshold 잠정값**: BEACON_RSSI_NEAR/MID, BEACON_LOST_TIMEOUT, BEACON_UNSTABLE_DELTA는 잠정값이다. #36 캘리브레이션 결과로 재조정 필요.
- **audio cue 미구별**: BEACON_LOST와 SIGNAL_UNSTABLE의 cueType은 현재 NONE이다. 구별되는 cue를 위해 #36과 연계해서 CueType enum에 LOST/UNSTABLE 추가 필요.

## 11. 관련 자료

- 본 API 명세: Issue #35 본문
- enum 확장 협의: Issue #38 (closed)
- 초기 머지 PR: #45
- 상위 그림: Issue #34
- 하드웨어 연계: Issue #36