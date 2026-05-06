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

## 제외 범위

- Firebase/FCM/지오펜싱 구현은 심현석 담당입니다.
- 비콘 거리 테스트 및 공간음향 방향 테스트 계획은 4월 김도성 범위에서 제외합니다.
