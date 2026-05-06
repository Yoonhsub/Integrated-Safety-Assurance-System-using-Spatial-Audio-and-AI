# Public Data Service - 김도성 담당 영역

공공데이터포털 기반 버스 도착/위치/저상버스 정보 연동 영역입니다.

## 4월 구현 범위

- 사용할 공공데이터 API 조사
- 정류장별 버스 도착 정보 조회 모듈
- 노선/차량 위치 정보 조회 가능성 확인 및 모듈화
- 저상버스 여부 필터링
- 혼잡도 필드가 제공될 경우 표준값으로 변환
- 심현석 백엔드가 사용할 수 있는 표준 JSON 응답 제공

## 표준 출력 계약

`services/public_data`는 공공데이터 원본 응답을 앱/백엔드가 직접 소비하는 형태로 노출하지 않고, 아래 공식 shared schema에 맞춘 표준 응답으로 변환한다.

```txt
packages/shared_contracts/api/bus_arrivals.response.schema.json
```

표준 출력 객체는 `BusArrivalsResponse` 계약을 따른다. 내부 Pydantic 모델명은 `NormalizedBusArrivalsResponse`일 수 있지만, app-facing/backend-facing 공식 계약명은 `BusArrivalsResponse`다.

주의:
- 공공데이터 원본 필드명은 내부 변환 단계에서만 사용한다.
- app-facing/backend-facing 출력에는 `stopName`, `source` 등 비계약 필드를 포함하지 않는다.
- `congestion` 정보가 없을 때도 필드를 생략하지 말고 명시적으로 `UNKNOWN`으로 표준화한다.
- 정의되지 않은 extra field는 normalized 모델 단계에서 허용하지 않는다.

## 공공데이터 API 조사 결과 (섹션 2)

> 이 절은 4월 섹션 2에서 김도성의 에이전트가 실제 공식 출처를 확인하고 정리한 1차 조사 결과이다.
> 최신 사양/필드/엔드포인트는 공공데이터포털 개별 활용 신청 페이지의 "참고문서"가 항상 최우선이며, 이 절은 보조 요약이다.
> 변동 가능한 정보는 본문에 "확인 필요"로 표기한다.

### 1. API 후보 비교

후보 우선순위는 ① 전국 단위 표준화 가능성, ② 김도성/팀 위치(청주, KR) 적용성, ③ 저상버스/혼잡도 필드 제공 여부 순으로 판단했다.

| 우선순위 | API | 제공기관 | 커버리지 | 저상버스 | 혼잡도 | 비고 |
|---|---|---|---|---|---|---|
| 1 | 국토교통부_(TAGO)_버스도착정보 (`ArvlInfoInqireService`) | 국토교통부 / TAGO 연계 | 전국 BIS 연계 도시 (도시코드 목록 조회로 확인) | 확인 필요 (vehicletp 계열) | 확인 필요 | 청주/충북 포함, 통합 표준화에 가장 적합 |
| 2 | 서울특별시_버스도착정보조회 서비스 | 서울특별시 (공유자원포털 인증키) | 서울 | **제공** (busType 0/1/2) | **제공** (reride_Num 0/3/4/5) | 필드 명세가 가장 명확. 풀버전 검증/대조용 |
| 3 | 경기도 GBIS `busarrivalservice/v2/getBusArrivalItemv2` | 경기도 | 경기 | 확인 필요 | 확인 필요 ("빈자리 수 정보는 2015~" 안내 존재) | stationId+routeId+staOrder 조합 호출 |
| 보조 | 국토교통부_(TAGO)_버스위치정보 (`BusLcInfoInqireService`) | 국토교통부 | 전국 BIS 연계 도시 | 해당 없음 | 해당 없음 | 노선 단위 위치만, 도착정보와 별개로 활용 |
| 보조 | 국토교통부_전국 버스정류장 위치정보 (파일데이터) | 국토교통부 | 전국 (연1회 갱신) | 해당 없음 | 해당 없음 | stopId↔좌표 매핑 보조 자료 |

이 표는 4월 18일 조사 시점 기준이다. 활용신청 가능 트래픽, 운영계정 승급 조건 등 정책은 변동될 수 있으므로 최종 확정 전 활용신청 페이지를 다시 확인한다.

#### 1차 출처
- 공공데이터포털 — 국토교통부_(TAGO)_버스도착정보: `https://www.data.go.kr/data/15098530/openapi.do`
- 공공데이터포털 — 국토교통부_(TAGO)_버스위치정보: `https://www.data.go.kr/data/15098533/openapi.do`
- 공공데이터포털 — 서울특별시_버스도착정보조회 서비스: `https://www.data.go.kr/data/15000314/openapi.do`
- 공공데이터포털 — 서울특별시_버스위치정보조회 서비스: `https://www.data.go.kr/data/15000332/openapi.do`
- 서울시 BIS Open API 레퍼런스 (응답 필드 명세): `http://api.bus.go.kr/contents/sub02/getArrInfoByRouteAll.html`
- 경기도 GBIS Open API: `https://www.gbis.go.kr/gbis2014/publicService.action?cmd=mBusArrival`

### 2. 정류장별 버스 도착 정보 — 요청 파라미터 정리

#### 2-1. TAGO `ArvlInfoInqireService` (1순위 후보)

| 항목 | 값 |
|---|---|
| 서비스 URL | `http://apis.data.go.kr/1613000/ArvlInfoInqireService` |
| 정류소별 도착예정 오퍼레이션 | `/getSttnAcctoArvlPrearngeInfoList` |
| 도시코드 조회 오퍼레이션 | `/getCtyCodeList` (도시코드 목록 조회) |

요청 파라미터 (확인 필요 — 활용신청 페이지의 첨부 명세서를 기준으로 최종 확정한다):
- `serviceKey` (필수): 공공데이터포털에서 발급받은 인증키
- `cityCode` (필수): 도시코드 (예: 서울 11, 부산 21, 대구 22, 인천 23, 광주 24, 대전 25, 울산 26, 경기 31, 충북 33 — **도시코드 매핑은 `getCtyCodeList`로 직접 확인한다. 본 README의 숫자는 일반 통념이며 변동 가능**)
- `nodeId` (필수): 정류소 ID (TAGO 표준)
- `numOfRows`, `pageNo`: 페이징
- `_type`: `xml` 또는 `json`

응답 형태: 표준 공공데이터 result wrapper(`response/header(resultCode,resultMsg)/body/items/item[]`). XML이 기본, `_type=json` 지정 시 JSON.

#### 2-2. 서울시 BIS `getArrInfoByRouteAll` (필드 명세 대조용 — 가장 상세)

| 항목 | 값 |
|---|---|
| 요청 URL | `http://ws.bus.go.kr/api/rest/arrive/getArrInfoByRouteAll` |
| 필수 파라미터 | `serviceKey`, `busRouteId` |
| 출력 형식 | XML (UTF-8) |

응답 핵심 필드 (서울시 BIS Open API 공식 레퍼런스 기준 — `http://api.bus.go.kr/contents/sub02/getArrInfoByRouteAll.html`):
- `stId` / `arsId` / `stNm`: 정류소 고유 ID / 정류소 번호 / 정류소명
- `busRouteAbrv` / `rtNm`: 안내용 노선명 / DB관리용 노선명
- `busRouteId`: 노선 ID
- `routeType`: 노선 유형 코드 (1:공항, 2:마을, 3:간선, 4:지선, 5:순환, 6:광역, 7:인천, 8:경기, 9:폐지, 10:관광, 13:동행, 14:한강, 15:심야, 0:공용)
- `vehId1` / `plainNo1`: 첫번째 도착예정 차량 ID / 차량번호
- `exps1` / `kals1` / `neus1`: 첫번째 도착예정 시간(초) — 여러 보정 모델 결과
- `arrmsg1`: 첫번째 도착정보 메시지(예: "곧 도착", "5분 후 도착")
- `busType1`: **첫번째 도착예정 차량유형** (0:일반버스, **1:저상버스**, 2:굴절버스) ← 저상버스 판별 핵심 필드
- `reride_Num1` / `rerdie_Div1`: **첫번째 도착예정 재차 인원 혼잡도** (0:데이터없음, 3:여유, 4:보통, 5:혼잡) ← 혼잡도 핵심 필드
- `full1`: 만차여부
- `isArrive1`: 도착출발 여부 (0:운행중, 1:도착)
- `isLast1`: 막차여부
- (위 필드들은 두번째 도착버스용 `*2`로도 동일하게 제공 — 응답 1건당 최대 2대)

### 3. 실시간 버스 위치 정보 제공 가능성

- **TAGO `BusLcInfoInqireService`**: 노선 단위 실시간 위치 조회 가능. **확인 필요** — 공식 활용신청 페이지의 응답 명세서로 위경도 필드 존재 여부와 갱신 주기를 최종 확인한다.
- **서울특별시 버스위치정보조회 서비스 (`/data/15000332`)**: 노선 ID와 정류소 구간 정보를 요청값으로 전달 — 위치, 도착 여부, 차량번호, 차량 유형, 혼잡도 제공 가능.
- 4월 김도성 범위 적용 방향: 공공데이터 위치정보는 **shared schema의 `BusArrivalsResponse`와 별개**이므로 4월 범위에서는 도착정보(`arrivalMinutes`, `remainingStops`)에 집중하고, 노선 위치 좌표는 향후 별도 표준화 대상으로만 메모해 둔다. 새 shared contract 추가가 필요해지면 즉시 충돌 이슈에 기록한다.

### 4. 저상버스 여부 필드

| API | 필드명 | 표현 | normalize 매핑 |
|---|---|---|---|
| 서울 BIS `getArrInfoByRouteAll` | `busType1`, `busType2` | "0"=일반, "1"=저상, "2"=굴절 | `lowFloor = (str(busType*) == "1")` (저상만 true, 그 외 false) |
| 서울 BIS 교통약자 전용 오퍼레이션 (`getLowArrInfoByStId`, `getLowArrInfoByRoute`) | (해당 오퍼레이션은 결과 자체가 저상버스 한정) | 결과 행 = 저상 | 결과 행에 대해 `lowFloor = true` 일괄 |
| TAGO `ArvlInfoInqireService` | 확인 필요 | 확인 필요 | 활용신청 명세서에서 `vehicletp` 계열 필드명/코드를 확정한 뒤 매핑한다. 미확인 단계에서는 `lowFloor = false`로 보수적 기본값을 두지 않고 mock 단계 유지. |

원칙:
- 원본 코드값(예: `"1"`)을 그대로 노출하지 않고 boolean으로만 normalize한다.
- 원본이 `"굴절(2)"`인 경우 — 4월 시점에는 저상이 아니므로 `lowFloor = false` (단, 굴절도 저상형이 있으면 향후 별도 검토. 현재는 서울 BIS 코드표대로 분리).
- 원본 응답이 vehicletp/busType 자체를 제공하지 않으면 `lowFloor = false`가 아니라 — 김도성 normalize는 `mock-only` 모드를 사용하고 실제 호출에서는 `lowFloor=False`로 단정하지 않는다. 데이터 부재 시 노출 정책은 섹션 6에서 확정한다.

### 5. 혼잡도 정보 제공 여부

| API | 필드명 | 원본 값 | 표준 enum 매핑 (`congestion`) |
|---|---|---|---|
| 서울 BIS `getArrInfoByRouteAll` | `reride_Num1`, `reride_Num2` | "0"=데이터없음, "3"=여유, "4"=보통, "5"=혼잡 | "0"→`UNKNOWN`, "3"→`LOW`, "4"→`NORMAL`, "5"→`HIGH` |
| TAGO `ArvlInfoInqireService` | 확인 필요 | 확인 필요 | 활용신청 명세 확인 후 매핑 표 보강 (섹션 4/6) |
| 경기도 GBIS `getBusArrivalItemv2` | "빈자리 수" 계열 (확인 필요) | 확인 필요 | 빈자리 수 → 혼잡도 환산은 단순 매핑이 어려움. 현재 매핑하지 않고 `UNKNOWN` 유지가 안전 |

원칙:
- `congestion` 필드 자체를 응답에서 **누락하지 않는다**. 원본이 없거나 미해석이면 `"UNKNOWN"` 명시.
- enum 외 값(예: `"NONE"`, `"-"`, 빈 문자열, null)은 모두 `UNKNOWN`으로 흡수한다.
- `LOW/NORMAL/HIGH/UNKNOWN` 4종 외 값은 normalize 단계에서 차단하며 `NormalizedBusArrival`은 `extra="forbid"`로 추가 필드를 거부한다.

### 6. 인증키 발급 환경 변동 (운영 메모)

- 서울 열린데이터광장 페이지 안내: **국가정보자원관리원 화재(2025-09-26)로 인해 신규 인증키 발급은 불가** — 기존 인증키는 사용 가능. 출처: `https://data.seoul.go.kr/dataList/OA-1095/F/1/datasetView.do`
- 위 영향으로 4월 MVP 단계에서는 **mock-first 전략**(`PUBLIC_DATA_USE_MOCK=true` 기본값)이 더더욱 합리적이다. 실 키 확보 가능 여부는 별도 충돌 이슈가 아니라 운영 의제로 둔다.

### 7. 환경변수 (정의 위치: `docs/rw/ENVIRONMENT_VARIABLES.md`)

| 변수 | 용도 | 4월 기본 사용 위치 |
|---|---|---|
| `PUBLIC_DATA_API_KEY` | 공공데이터포털 인증키 | `DataGoKrClient.__init__` |
| `PUBLIC_DATA_BASE_URL` | API 기본 URL (기본 `https://apis.data.go.kr`) | `DataGoKrClient.__init__` |
| `PUBLIC_DATA_CITY_CODE` | TAGO 도시코드 (예: 청주/충북 33) | **확인 필요** — 섹션 4에서 클라이언트 호출에 통합 |
| `PUBLIC_DATA_USE_MOCK` | mock 응답 사용 여부 (기본 `true`) | **확인 필요** — 섹션 4에서 BusArrivalsService에 mock/real 분기 추가 |

`PUBLIC_DATA_CITY_CODE`와 `PUBLIC_DATA_USE_MOCK`는 docs에는 정의되어 있지만 4월 18일 시점 코드에서 아직 사용되지 않는다. 섹션 4의 명시 목표("환경변수 사용 방식 정리", "mock mode와 real mode 경계 정리")에서 통합한다.

### 8. 표준 출력 예시

표준 응답(`BusArrivalsResponse`) 예시는 `services/public_data/examples/mock_bus_arrivals.json`을 참조한다. 4개 케이스를 포함하여 후행 팀원이 다음을 검증할 수 있다.

- 저상버스 true / 일반버스 false 혼합
- `congestion` enum 4종(LOW/NORMAL/HIGH/UNKNOWN) 모두 등장
- `remainingStops` 정수 / 0 / null 케이스
- `arrivalMinutes` 0(곧 도착) / 일반 / 큰 값

이 mock JSON은 `bus_arrivals.response.schema.json`을 stdlib 수준에서 통과한다. pydantic/jsonschema 정식 검증은 의존성 설치 환경에서 추가로 수행한다.

## 제외 범위

- Firebase/FCM/지오펜싱 구현은 심현석 담당입니다.
- 비콘 거리 테스트 및 공간음향 방향 테스트 계획은 4월 김도성 범위에서 제외합니다.
