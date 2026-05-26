# Passenger Sensor Lifecycle Guide - V2 Section 10

이 문서는 `apps/passenger_app/**`를 직접 수정하지 않고, BLE 권한/위치 권한/앱 lifecycle 상황에서 `packages/mobile_sensors`를 안전하게 연결하는 기준을 정리한다.

## 목표

섹션 10의 검증 대상은 다음 상황이다.

```txt
- 권한 없음
- 권한 거부
- 앱 재시작
- 스캔 중지
- 스캔 재개
- background/foreground 전환
```

이 패키지는 권한 요청 UI나 background service를 구현하지 않는다. 앱은 플랫폼 권한 확인 결과를 `PassengerSensorPermissionSnapshot`으로 변환하고, lifecycle 상태를 `PassengerSensorLifecyclePhase`로 변환해 판단한다.

## 권한 상태 기준

```txt
UNKNOWN: 아직 권한 상태를 확인하지 않음. live scan 시작 금지, 앱에서 권한 확인 필요
READY: BLE/위치 권한과 기기 서비스가 준비됨. live scan 시작 가능
BLUETOOTH_PERMISSION_DENIED: Bluetooth 권한 거부. live scan 시작 금지, 권한 안내 UI 필요
LOCATION_PERMISSION_DENIED: 위치 권한 거부. live scan 시작 금지, 권한 안내 UI 필요
BLUETOOTH_OFF: Bluetooth 꺼짐. live scan 시작 금지, mock/replay fallback 가능
LOCATION_OFF: 위치 서비스 꺼짐. live scan 시작 금지 또는 플랫폼별 제한 안내 필요
UNAVAILABLE: 기기/플랫폼 기능 없음. live scan 대신 mock/replay 또는 기능 비활성화
```

권한 snapshot 예시는 다음과 같다.

```dart
final denied = PassengerSensorPermissionSnapshot.fromStatus(
  status: PassengerSensorPermissionStatus.bluetoothPermissionDenied,
  bluetoothPermissionGranted: false,
  locationPermissionGranted: true,
  bluetoothEnabled: true,
  locationServiceEnabled: true,
);
```

## Lifecycle 판단 기준

`PassengerSensorLifecyclePolicy`는 권한 상태와 앱 phase를 합쳐 scan 동작을 결정한다.

```dart
final policy = PassengerSensorLifecyclePolicy();
final decision = policy.decide(
  permission: await sensorService.checkPermissionStatus(),
  phase: PassengerSensorLifecyclePhase.resumed,
  wasScanning: false,
);

if (decision.shouldStartScan) {
  proximitySubscription = sensorService.watchProximityEvents().listen(handleEvent);
}

if (decision.shouldStopScan) {
  await proximitySubscription.cancel();
  await sensorService.stop();
}
```

## 상황별 권장 처리

### 1. 권한 없음 또는 권한 미확인

```txt
입력: PassengerSensorPermissionStatus.UNKNOWN
권장 action: USE_MOCK_REPLAY 또는 DO_NOTHING
live scan: 시작하지 않음
앱 처리: 권한 확인/요청 UI로 이동하거나 mock fixture 사용
```

### 2. 권한 거부

```txt
입력: BLUETOOTH_PERMISSION_DENIED 또는 LOCATION_PERMISSION_DENIED
권장 action: SHOW_PERMISSION_RATIONALE
live scan: 시작하지 않음
앱 처리: 권한 안내 UI, 설정 이동 안내, mock/replay fallback 선택
```

### 3. 앱 background/paused

```txt
입력: BACKGROUND 또는 PAUSED
권장 action: STOP_SCAN
live scan: 중지
앱 처리: StreamSubscription.cancel() 후 sensorService.stop()
```

### 4. 앱 resumed/restarted

```txt
입력: RESUMED 또는 RESTARTED + READY
권장 action: RESUME_SCAN 또는 KEEP_SCANNING
live scan: 기존 subscription이 없으면 재구독
앱 처리: 권한 재확인 후 watchProximityEvents()/watchAudioCues() 재연결
```

### 5. 화면 dispose

```txt
입력: DISPOSED
권장 action: STOP_SCAN
live scan: 중지
앱 처리: subscription cancel 후 sensorService.dispose()
```

## Mock/replay fallback 기준

실제 BLE 없이 앱 연결부를 확인해야 하거나, 권한/기기 서비스가 막힌 환경에서는 live scanner 대신 mock/replay를 사용한다.

```dart
final adapter = MobileSensorPassengerAdapter(
  scanner: MockBeaconScanner(fixture.toSignals()),
  permissionProvider: () async => PassengerSensorPermissionSnapshot.fromStatus(
    status: PassengerSensorPermissionStatus.unknown,
  ),
);
```

이 fallback은 시연/개발 검증용이며 실제 승차 안전 판단의 live sensor 결과로 간주하면 안 된다.

## 범위 제한

```txt
이 문서는 구현하지 않음:
- Passenger App 권한 요청 화면
- Android/iOS manifest 또는 Info.plist 수정
- background service
- 실제 Bluetooth 설정 화면 이동
- 실제 BLE 실기기 검증
- 실제 TTS 또는 골전도 이어폰 출력 제어
```
