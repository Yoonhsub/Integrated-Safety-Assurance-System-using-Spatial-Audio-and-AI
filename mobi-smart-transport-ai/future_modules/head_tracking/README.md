# Head Tracking - Future Module

헤드트래킹 센서는 추후 구매 예정이므로 4월 구현 범위에서 제외합니다.

## 현재 상태

- 구현 금지
- 인터페이스/계약 프레임만 유지
- 안준환의 4월 BLE/RSSI 구현과 혼동 금지

## 향후 예상 입력

```json
{
  "yaw": 0.0,
  "pitch": 0.0,
  "roll": 0.0,
  "timestamp": "2026-09-01T00:00:00+09:00"
}
```


## 예약 enum

`packages/shared_contracts/events/event_types.json`의 `future_head_tracking_status`는 향후 센서 상태 이벤트용 예약 enum입니다.
4월에는 앱/backend 이벤트로 발행하지 않습니다.
현재 `head_tracking_event.schema.json`의 `yaw`/`pitch`/`roll` 데이터 계약과 혼동하지 않습니다.

## 향후 연결 후보

- `packages/mobile_sensors`
- `future_modules/spatial_audio`
- 사용자 앱 내 방향 안내 UI
