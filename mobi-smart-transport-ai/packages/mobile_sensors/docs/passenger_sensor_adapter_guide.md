# Passenger Sensor Adapter Guide - V2 Section 9

이 문서는 `apps/passenger_app/**`를 직접 수정하지 않고, Passenger App이 `packages/mobile_sensors`를 어떻게 소비하면 되는지 정리한 연결 기준이다.

## 목적

섹션 9의 목표는 Flutter Passenger App이 센서 이벤트를 받을 수 있도록 다음 기준을 고정하는 것이다.

```txt
- sensor service interface
- stream subscription
- dispose lifecycle
- permission status
```

이 문서는 앱 UI, 권한 요청 화면, TTS 실행, 블루투스 이어폰 제어를 구현하지 않는다. 해당 작업은 Passenger App 또는 오디오 출력 계층에서 수행한다.

## 권장 import

```dart
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
```

## Sensor service interface

Passenger App은 `PassengerSensorService` interface를 기준으로 센서 연결부를 작성할 수 있다.

```dart
final sensorService = MobileSensorPassengerAdapter(
  scanner: FlutterBlueBeaconScanner(),
  config: const PassengerSensorAdapterConfig(
    targetBeaconId: 'MOBI_STOP_BEACON_001',
    suppressRepeatedAudioCues: true,
  ),
  permissionProvider: () async {
    // 앱 계층에서 permission_handler 또는 플랫폼 API로 확인한 결과를 변환한다.
    return PassengerSensorPermissionSnapshot.ready();
  },
);
```

실제 BLE 권한 요청, 위치 권한 요청, Bluetooth 활성화 안내 화면은 앱에서 처리한다. 패키지는 권한 상태를 조회·기록할 수 있는 `PassengerSensorPermissionSnapshot`만 제공한다.

## Stream subscription 기준

Proximity event만 소비할 경우:

```dart
late final StreamSubscription<ProximityEvent> sensorSubscription;

Future<void> startSensor() async {
  final permission = await sensorService.checkPermissionStatus();
  if (!permission.canStartScan) {
    // 앱에서 권한 안내 UI 또는 fallback 안내를 처리한다.
    return;
  }

  sensorSubscription = sensorService.watchProximityEvents().listen((event) {
    // event.eventType: BEACON_NEAR, BEACON_LOST, APPROACHING_STOP, LEAVING_STOP
    // 앱 상태 관리, 로그, 화면 안내, TTS queue 연결은 앱 담당이다.
  });
}
```

Audio cue payload까지 소비할 경우:

```dart
late final StreamSubscription<BoneConductionAudioCue> cueSubscription;

Future<void> startAudioCue() async {
  cueSubscription = sensorService.watchAudioCues().listen((cue) {
    // 실제 TTS 호출은 앱 또는 오디오 출력 계층에서 수행한다.
    // cue.message를 읽거나, cue.urgency에 따라 알림 우선순위를 조정할 수 있다.
  });
}
```

## Dispose lifecycle 기준

화면이 닫히거나 앱 lifecycle이 정지 상태로 들어가면 stream subscription을 먼저 취소하고 adapter를 정리한다.

```dart
Future<void> stopSensor() async {
  await sensorSubscription.cancel();
  await cueSubscription.cancel();
  await sensorService.dispose();
}
```

권장 lifecycle은 다음과 같다.

```txt
initState / viewModel start:
1. checkPermissionStatus()
2. watchProximityEvents() 또는 watchAudioCues() 구독

pause / route leave / logout:
1. StreamSubscription.cancel()
2. sensorService.stop()

dispose:
1. StreamSubscription.cancel()
2. sensorService.dispose()
```

`dispose()` 이후 같은 adapter를 다시 구독하면 `StateError`가 발생한다. 앱은 새 화면 진입 시 새 `MobileSensorPassengerAdapter`를 만들면 된다.

## Permission status 기준

`PassengerSensorPermissionStatus` 값은 다음과 같다.

```txt
UNKNOWN: 패키지 내부에서 권한 상태를 확인하지 않음
READY: BLE/위치 권한과 기기 서비스가 준비됨
BLUETOOTH_PERMISSION_DENIED: Bluetooth 권한 거부
LOCATION_PERMISSION_DENIED: 위치 권한 거부
BLUETOOTH_OFF: Bluetooth 비활성화
LOCATION_OFF: 위치 서비스 비활성화
UNAVAILABLE: 기기나 플랫폼이 센서 기능을 제공하지 않음
```

앱은 `permission.canStartScan`이 false이면 BLE scan을 시작하지 않고 권한 안내 UI 또는 mock/replay fallback을 선택해야 한다.

## Mock/replay 연결

실제 BLE 없이 Passenger App 연결부를 테스트할 때는 `MockBeaconScanner` 또는 `BeaconReplayFixture`를 사용한다.

```dart
final adapter = MobileSensorPassengerAdapter(
  scanner: MockBeaconScanner(fixture.toSignals()),
  permissionProvider: () async => PassengerSensorPermissionSnapshot.ready(),
);
```

이 방식은 실기기 검증이 아니라 앱 연결부의 stream subscription, event handling, dispose 흐름을 확인하기 위한 mock-first 검증이다.

## 범위 제한

```txt
수정하지 않는 범위:
- apps/passenger_app/**
- apps/driver_app/**
- backend/**
- services/public_data/**
- ai_vision/**
- future_modules/head_tracking/**
- future_modules/spatial_audio/**
- packages/shared_contracts/**
```

섹션 9의 산출물은 Passenger App이 사용할 수 있는 adapter 기준과 문서이며, 실제 앱 UI 연결 PR은 Passenger App 담당자가 수행한다.
