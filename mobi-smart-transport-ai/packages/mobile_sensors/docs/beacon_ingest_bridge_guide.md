# Beacon Ingest Bridge Guide

This guide covers the @ajh1206 side of #52/#53: turning BLE scanner output into backend `/api/v3/beacon/ingest` requests.

## Goal

The bridge connects this flow:

```txt
FlutterBlueBeaconScanner or MockBeaconScanner
-> Stream<BeaconSignal>
-> BeaconIngestPayload
-> POST /api/v3/beacon/ingest
-> backend /api/v3/beacon/latest
```

It does not implement Passenger App UI, PWA polling, or backend target/wrong policy.

## Real A/B beacon identifiers

The current field report says the two physical beacons share UUID/major/minor and differ by MAC:

```txt
target candidate : C3:00:00:5C:B9:47
wrong candidate  : C3:00:00:5C:B9:48
```

On Android, first confirm what `flutter_blue_plus` exposes as `result.device.remoteId.str`. If the advertised local name is non-empty, the package default resolver may prefer the name as `beaconId`. For the real A/B validation, inject a resolver that keeps the remote id:

```dart
final scanner = FlutterBlueBeaconScanner(
  beaconIdResolver: (result) => result.device.remoteId.str,
);
```

## Bridge usage

```dart
final scanner = FlutterBlueBeaconScanner(
  beaconIdResolver: (result) => result.device.remoteId.str,
);

final client = BeaconIngestClient(
  baseUri: Uri.parse('http://10.0.2.2:8000'),
);

final bridge = BeaconIngestBridge(
  scanner: scanner,
  client: client,
  sessionId: 'demo-session',
  deviceId: 'android-collector-01',
  identityResolver: (signal) => BeaconIngestIdentity(
    beaconId: 'same-uuid-major-minor',
    macAddress: signal.beaconId,
    routeNo: '502',
    busId: signal.beaconId == 'C3:00:00:5C:B9:47'
        ? 'BUS_502_TARGET'
        : 'BUS_502_OTHER',
  ),
);

await for (final result in bridge.sendScan()) {
  print(result.body);
}
```

For an Android emulator hitting a host backend, `10.0.2.2` is usually the host loopback address. For a physical phone, use the VM/backend LAN address.

## Hardware-free smoke test

Use `MockBeaconScanner` to verify request shape before touching real BLE:

```dart
final scanner = MockBeaconScanner([
  BeaconSignal(
    beaconId: 'C3:00:00:5C:B9:47',
    rssi: -55,
    estimatedDistanceMeters: 2.0,
    signalLevel: BeaconSignalLevel.close,
    lastDetectedAt: DateTime.now(),
  ),
]);
```

The fixture `fixtures/real_beacon_ab_ingest_samples.json` contains target/wrong sample payloads.

## Backend dependency

The bridge sends `macAddress` when it can resolve a MAC-like identifier. The backend must accept that field and use it for target/wrong matching. Until the backend MAC mapping patch is applied, strict backend schemas may reject `macAddress`.
