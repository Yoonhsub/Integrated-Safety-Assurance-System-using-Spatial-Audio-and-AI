# V3 Beacon API — 하드웨어 테스트 가이드

본 문서는 @ajh1206의 #36 하드웨어 테스트에서 V3 Beacon Ingest API를 사용하는 방법을 안내한다. Android BLE bridge 또는 실제 BLE scanner가 본 API를 호출하면 백엔드가 RSSI 판정 결과를 반환하고, PWA가 그 상태를 polling해서 화면·음성 cue를 재생한다.

관련 이슈: #35 (백엔드), #36 (하드웨어)  
운영자: @doseong13

## 0. 빠른 시작

### 0.1 endpoint 3개

| 메서드 | 경로 | 역할 |
|---|---|---|
| POST | `https://mobi.35.232.72.197.nip.io/api/v3/beacon/ingest` | RSSI 이벤트 전송 |
| GET | `https://mobi.35.232.72.197.nip.io/api/v3/beacon/latest` | 최신 상태 조회 |
| POST | `https://mobi.35.232.72.197.nip.io/api/v3/beacon/reset` | 세션 초기화 |

### 0.2 30초 동작 확인 (수동 curl)

다른 작업 시작 전에 본 API가 동작하는지 한 번 확인:

```bash
# ingest 한 번
curl -X POST https://mobi.35.232.72.197.nip.io/api/v3/beacon/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "sessionId": "ajh-test",
    "deviceId": "ajh-test-device",
    "beaconId": "MOBI_BUS_502_TARGET",
    "rssi": -55,
    "source": "MANUAL_TEST",
    "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%S%z)"'"
  }'

# latest 조회
curl https://mobi.35.232.72.197.nip.io/api/v3/beacon/latest?sessionId=ajh-test
```

`decision: TARGET_BUS_NEAR` 응답이 나오면 정상.

## 1. POST /ingest — RSSI 이벤트 전송

### 1.1 요청 형식

```json
{
  "sessionId": "demo-session",
  "deviceId": "android-ajh-test",
  "beaconId": "MOBI_BUS_502_TARGET",
  "busId": "BUS_502_NOW",
  "routeNo": "502",
  "rssi": -64,
  "distanceMeters": 4.2,
  "source": "REAL_BLE",
  "timestamp": "2026-06-04T14:00:00+09:00"
}
```

### 1.2 필드 설명

| 필드 | 필수 | 타입 | 의미 |
|---|---|---|---|
| sessionId | optional | string | Mock 시나리오 세션 ID. 기본 "demo-session" |
| deviceId | yes | string | RSSI 수집 장치 식별자 (Android 단말, bridge 등) |
| beaconId | yes | string | 비컨 식별자. **"TARGET" 포함 시 target으로 판정** |
| busId | optional | string | 버스 식별자. target/wrong 판정 보조 |
| routeNo | optional | string | 노선 번호 |
| rssi | yes | int (-120 ~ 0) | RSSI 값 (dBm) |
| distanceMeters | optional | float (≥ 0) | 추정 거리. 있으면 RSSI보다 우선 사용 |
| source | yes | enum | "REAL_BLE", "MANUAL_TEST", "MOCK_BRIDGE" 중 하나 |
| timestamp | yes | RFC3339 datetime | 이벤트 발생 시각 |

### 1.3 target/wrong 판정 규칙

현재 초기 규칙: **`beaconId` 또는 `busId` 문자열에 "TARGET" 포함 시 target으로 판정**.

예시:

| beaconId | 판정 |
|---|---|
| MOBI_BUS_502_TARGET | target |
| MOBI_BUS_502 | wrong |
| MOBI_BUS_100_WRONG | wrong |
| BUS_502_TARGET | target |

캘리브레이션 후 세션의 target_bus_id와 매핑하는 방식으로 확장 예정.

### 1.4 응답 형식

```json
{
  "sessionId": "demo-session",
  "lastUpdatedAt": "2026-06-04T14:00:00+09:00",
  "beaconId": "MOBI_BUS_502_TARGET",
  "routeNo": "502",
  "rssi": -64,
  "distanceMeters": 4.2,
  "proximity": "MID",
  "decision": "TARGET_BUS_MID",
  "phase": "WAITING_FOR_BUS",
  "cueType": "TARGET_BUS_MID",
  "scriptLineId": "bus_approaching",
  "confidence": 0.78,
  "warnings": []
}
```

### 1.5 응답 필드 의미

| 필드 | 의미 |
|---|---|
| proximity | NEAR / MID / FAR / LOST / UNSTABLE |
| decision | TARGET_BUS_NEAR / TARGET_BUS_MID / TARGET_BUS_FAR / WRONG_BUS_NEAR / BEACON_LOST / SIGNAL_UNSTABLE / NO_BEACON |
| phase | GuidanceState enum 값 (WAITING_FOR_BUS, BOARDING_CONFIRMATION 등) |
| cueType | CueType enum 값 (TARGET_BUS_*, WRONG_BUS_NEAR, NONE 등) |
| scriptLineId | bus_approaching / bus_stopped / wrong_bus_warning / signal_lost 등 |
| confidence | 0.0 ~ 1.0 (판정 신뢰도) |
| warnings | 경고 메시지 목록 (LOST 시 "No beacon signal for over 5 seconds" 등) |

## 2. GET /latest — 최신 상태 조회

### 2.1 요청
GET /api/v3/beacon/latest?sessionId=<session-id>

기본 sessionId는 "demo-session".

### 2.2 응답

POST /ingest와 동일한 응답 형식.

### 2.3 lost timeout 자동 처리

**중요**: 본 endpoint는 호출 시점에 lost timeout 자동 체크를 수행한다.

- 마지막 ingest로부터 `BEACON_LOST_TIMEOUT` (기본 5초) 이상 경과 시
- 자동으로 `decision: BEACON_LOST`로 전환됨
- `rssi`, `distanceMeters` 필드는 `null`로 반환
- `warnings`에 "No beacon signal for over 5 seconds" 추가

### 2.4 404 응답

해당 sessionId에 대한 이벤트가 아직 없으면 (ingest 전이거나 reset 후) 404 반환:

```json
{
  "error": {
    "code": "NOT_FOUND",
    "message": "No beacon state for session 'xxx'. Call /ingest first.",
    "detail": {...}
  }
}
```

## 3. POST /reset — 세션 초기화

### 3.1 요청
POST /api/v3/beacon/reset?sessionId=<session-id>

### 3.2 응답

```json
{
  "sessionId": "demo-session",
  "status": "reset"
}
```

데모 시작 전 깨끗한 상태로 시작하고 싶을 때 호출.

## 4. RSSI 판정 규칙 (현재 기본값)

| 판정 | RSSI 기준 | 거리 기준 (distanceMeters 우선) | phase | cueType |
|---|---|---|---|---|
| TARGET_BUS_FAR | < -75 | > 10m | WAITING_FOR_BUS | TARGET_BUS_FAR |
| TARGET_BUS_MID | -75 ~ -62 | 3 ~ 10m | WAITING_FOR_BUS | TARGET_BUS_MID |
| TARGET_BUS_NEAR | ≥ -62 | ≤ 3m | BOARDING_CONFIRMATION | TARGET_BUS_NEAR |
| WRONG_BUS_NEAR | wrong beacon, ≥ -75 | wrong beacon, ≤ 10m | WAITING_FOR_BUS | WRONG_BUS_NEAR |
| BEACON_LOST | 5초+ 미감지 | - | WAITING_FOR_BUS | NONE (#36 연계) |
| SIGNAL_UNSTABLE | 20+ 급변 | - | 기존 phase 유지 | NONE (#36 연계) |

distanceMeters가 요청에 포함되어 있으면 RSSI보다 우선 사용한다.

## 5. Threshold 환경변수 (캘리브레이션)

RSSI는 기기마다 편차가 크므로, AJH 실측 결과로 다음 환경변수를 조정한다.

| 변수 | 기본값 | 의미 |
|---|---|---|
| `BEACON_RSSI_NEAR` | -62 | NEAR 판정 RSSI 기준 |
| `BEACON_RSSI_MID` | -75 | MID 판정 RSSI 기준 |
| `BEACON_LOST_TIMEOUT` | 5 | LOST 자동 전환 시간 (초) |
| `BEACON_UNSTABLE_DELTA` | 20 | SIGNAL_UNSTABLE 감지 RSSI 변화량 |

### 5.1 캘리브레이션 절차 (제안)

1. 비컨 1개를 고정 위치에 두고, AJH 단말로 다음 거리에서 RSSI 측정:
   - 0.5m, 1m, 3m, 5m, 10m
2. 각 거리별 20~30초간 측정한 평균/중앙값/최소/최대 RSSI 기록
3. 결과를 본인(@doseong13)과 공유
4. 결과 기반으로 threshold 조정 후 본인이 VM 재배포

### 5.2 캘리브레이션 결과 공유 양식

[캘리브레이션 결과]
비컨 ID:
측정 단말:
측정 환경: 실내 / 실외 / 사람 가림 유무

거리             avgRSSI  median     min       max  lost횟수
0.5m(1m ~ 10m)    -45       -44     -50       -42     0

권장 threshold 변경:

BEACON_RSSI_NEAR: -62 → ?
BEACON_RSSI_MID: -75 → ?
BEACON_LOST_TIMEOUT: 5 → ?

## 6. 실제 비컨 테스트 시나리오 (참고)

#36 문서 §8에 명시된 프로토콜에 따라 다음 3가지 시나리오 권장.

### 6.1 A. 타야 할 버스 vs 잘못된 버스

1. 비컨 A를 `MOBI_BUS_502_TARGET`으로 지정
2. 비컨 B를 `MOBI_BUS_511_WRONG`으로 지정
3. B를 먼저 폰 가까이 가져감 → `decision: WRONG_BUS_NEAR` 확인
4. B를 멀리하고 A를 가까이 → `decision: TARGET_BUS_NEAR` 확인

### 6.2 B. 거리 기반 접근/멀어짐

1. 비컨 A를 10m 이상 멀리 둠
2. 5m, 3m, 1m, 0.5m 순서로 접근
3. 각 거리에서 `proximity` 변화 확인 (FAR → MID → NEAR)

### 6.3 C. 사람 기반 시나리오

#36 문서 §8.C 참조. 본 API는 그 시나리오에서 ingest/latest 호출을 받는 백엔드 역할.

## 7. 로그 확인 (디버깅용)

테스트 중 본 API 호출이 정상 처리됐는지 확인하려면 VM 로그를 확인한다.

### 7.1 실시간 로그 (follow 모드)

```bash
sudo journalctl -u mobi-backend.service -f
```

새 요청이 올 때마다 로그가 갱신된다. Ctrl+C로 종료.

### 7.2 최근 로그

```bash
# 최근 50줄
sudo journalctl -u mobi-backend.service -n 50 --no-pager

# 최근 5분
sudo journalctl -u mobi-backend.service --since "5 minutes ago" --no-pager
```

### 7.3 특정 endpoint 호출 필터

```bash
sudo journalctl -u mobi-backend.service --since "10 minutes ago" --no-pager | grep "v3/beacon"
```

## 8. 자주 발생하는 에러

### 8.1 422 Unprocessable Entity

요청 페이로드의 필드가 잘못된 경우.

원인:
- 필수 필드 누락 (`rssi`, `deviceId`, `beaconId`, `source`, `timestamp`)
- `source` 값이 enum에 없음 (REAL_BLE / MANUAL_TEST / MOCK_BRIDGE만 허용)
- `rssi`가 범위 밖 (-120 ~ 0 외)
- `timestamp` 형식 오류

해결: 응답 본문에 어떤 필드가 어떻게 잘못됐는지 명시되어 있음. 그것을 보고 수정.

### 8.2 404 (GET /latest)

해당 sessionId에 대해 ingest를 한 번도 호출 안 했거나, reset 직후.

해결: 먼저 ingest 한 번 호출 → 그 후 latest 조회.

### 8.3 BEACON_LOST가 너무 자주 발생

원인: BLE scanner 응답 주기가 5초보다 김. 또는 클라이언트가 ingest 호출 빈도가 낮음.

해결:
- BLE scanner 응답 주기 단축 (Android에서 scan 간격 설정)
- 또는 본인에게 `BEACON_LOST_TIMEOUT` 환경변수 증가 요청 (예: 10초)

### 8.4 SIGNAL_UNSTABLE이 자주 발생

원인: RSSI 변동폭이 큼 (실내외 전환, 사람 가림, 멀티패스 등).

해결:
- 측정 환경 안정화 (실외 정류장 환경 등)
- 또는 본인에게 `BEACON_UNSTABLE_DELTA` 환경변수 증가 요청 (예: 30)

## 9. 본인(@doseong13) 지원 요청 방식

다음 상황에서 본인에게 알림:

| 상황 | 알림 방식 | 본인 대응 |
|---|---|---|
| API 호출이 매번 422 / 500 에러 | 단톡 또는 이슈 #35 댓글 | 로그 분석 후 디버깅 |
| RSSI 캘리브레이션 결과 공유 | 단톡 (위 §5.2 양식) | threshold 조정 + VM 재배포 |
| BEACON_LOST/UNSTABLE 너무 자주 | 단톡 | timeout/delta 환경변수 조정 검토 |
| 새 endpoint나 필드 필요 | 이슈 #35 또는 #36 댓글 | 협의 후 추가 작업 |

## 10. 한계 사항 (인지 사항)

- **in-memory 저장**: 본인 백엔드 재시작 시 모든 세션 상태 초기화. 테스트 중간에 재시작 일어나면 latest 조회 시 404.
- **단일 워커**: 멀티워커 전환 시 메모리 dict가 공유되지 않음. 현재 구성에서는 문제 없음.
- **audio cue 미구별**: BEACON_LOST와 SIGNAL_UNSTABLE의 cueType은 현재 `NONE`이다. AJH가 #36 작업에서 CueType에 LOST/UNSTABLE 값 추가 후 본인이 백엔드 매핑 수정.

## 11. 관련 자료

- 백엔드 본 API 명세: Issue #35
- 본 API 운영 가이드: `docs/v3/beacon-ingest-deployment.md`
- 하드웨어 테스트 큰그림: Issue #36
- 상위 그림: Issue #34