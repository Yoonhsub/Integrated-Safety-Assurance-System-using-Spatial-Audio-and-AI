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

On Android, first confirm what `flutter_blue_plus` exposes as `result.device.remoteId.str`. The default resolver now keeps remoteId because advertising names may be shared. A remoteId is a collector identity, not proof of a specific bus. The A/B report does not establish vehicle registration. An explicit equivalent resolver is:

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
    beaconId: signal.beaconId,
    macAddress: signal.beaconId,
    // No verified vehicle registry: leave busId and routeNo unset.
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


## Observation time and safety policy (2026-10)

- Installed/tested flutter_blue_plus 1.36.8 accumulates scan results. Each
  `ScanResult.timeStamp` is assigned in the Dart platform callback, not at RF
  reception. Preserve this time as `lastDetectedAt` and serialize UTC as ingest
  `timestamp`. Never replace it with list emission, HTTP send, or server time.
- Continuous updates are enabled. A remoteId/timestamp watermark suppresses
  cached, duplicate and reversed callbacks before RSSI smoothing. Callbacks from
  before this scan, future callbacks and callbacks at least 5 seconds old are
  discarded. A fresh callback after a loss resets smoothing. Scan timeout and
  explicit stop close the stream even without another packet.
- Backend requires a timezone offset. Age must satisfy `0 <= age <
  BEACON_LOST_TIMEOUT` (default 5 seconds); timestamps must be strictly newer
  than the session's last accepted observation. Equal timestamps from multiple
  collectors are conservatively ignored. Rejected observations do not refresh
  deadlines or replace stored state. With no accepted state, ingest returns a
  hold response and `/latest` remains 404.
- Server observation age and monotonic deadline both bound validity. `/latest`
  reports BEACON_LOST at expiry or a backward wall-clock jump; `lastUpdatedAt`
  remains the last observation time. RSSI history is scoped by session, device
  and beacon. A gap or unstable signal cannot preserve boarding confirmation.
- `REAL_BLE` always yields NO_BEACON / WAITING_FOR_BUS / confidence 0 with
  UNVERIFIED_IDENTITY, even for IDs containing TARGET or client-provided busId.
  NO_BEACON here means no confirmed target; warnings distinguish unknown identity
  from absent radio reception. No new enum was introduced.
- Exact synthetic MOBI_BUS_502_TARGET/BUS_502_NOW/502 and
  MOBI_BUS_100_WRONG/BUS_100/100 fixtures work only for MANUAL_TEST/MOCK_BRIDGE,
  USE_MOCK_DATA=true and non-live PUBLIC_DATA_USE_MOCK. They are not a registry.
- Optional macAddress is accepted as collector metadata, never identity proof.
  Server and collector clocks must be synchronized; no future skew allowance is
  applied. Client timestamps are assertions, not authenticated evidence.
- This ingest store is not the guidance session's target-bus registry. Live
  ASK_CAN_BOARD_CURRENT_BUS remains on the existing hold path. Before enabling
  live permission: provision trusted vehicle/beacon bindings, verify selected
  vehicle/session ownership, authenticate collectors, test clock/transport
  latency, MAC/platform stability, Bluetooth loss and reacquisition on hardware.
- Memory/lock/deadlines are process-local. Multi-worker persistence and cross-
  process ordering require a shared store before deployment. Passive BLE IDs
  can be spoofed and proximity alone does not prove boarding is safe.

Hardware-free tests inject scan callbacks and clocks. They do not demonstrate
RF delivery timing, permissions, OS background behavior, or bus identity.
