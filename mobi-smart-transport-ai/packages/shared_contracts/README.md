# Shared Contracts

팀원별 구현체 간 병합 충돌과 응답 형식 혼선을 막기 위한 공통 계약 영역입니다.

이 영역은 다음을 포함합니다.

- API 요청/응답 JSON Schema
- Firebase Realtime Database 논리 스키마
- 이벤트 타입 및 상태 enum
- 모듈 간 데이터 교환 표준

## 수정 원칙

개별 팀원 에이전트가 임의로 수정하지 않습니다. 수정 필요 시 `충돌 이슈.md`에 기록하고 관련 팀원과 합의해야 합니다.


## 현재 API 스키마 목록

```txt
api/bus_arrivals.response.schema.json
api/driver_ride_requests.response.schema.json
api/geofence_check.request.schema.json
api/geofence_check.response.schema.json
api/notification.request.schema.json
api/notification.response.schema.json
api/ride_request.create.request.schema.json
api/ride_request.schema.json
api/ride_request.status_update.request.schema.json
```

성공 응답은 `success/data/message/timestamp` wrapper 없이 각 스키마 객체를 그대로 반환한다.
