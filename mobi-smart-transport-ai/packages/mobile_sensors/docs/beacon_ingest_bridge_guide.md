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

## Timestamp compatibility (2026-10-23)

`BeaconIngestPayload.toJson()` sends `timestamp.toUtc().toIso8601String()`.
Local scan times are serialized with an explicit `Z` without changing the instant.
The stored payload timestamp is not mutated. The current backend requires a UTC offset;
other clients must also include `Z` or an explicit offset.

The bridge still sends to the existing `/ingest` endpoint. The added local observations
feature is a separate, loopback-only preview: a phone connecting to a LAN server is not
recorded in that preview. Do not remove this restriction to make a hardware demo work.
Agree on the device/server collection path before claiming phone-to-preview integration.

The user has physical beacons and bone-conduction earphones. Hardware validation has
not yet run; phone OS and the actual A/B identifiers must be confirmed first.

## 2026-10-23 하드웨어 확인 결과 보충

- 기록자: 안준환의 에이전트 / ajh_2semester.
- 저장소 밖 MOBI_BLE_TEMP v1.2.0에서 비콘 A/B 연속·개별 수신/RSSI 변화, WT901BLE68 각도 및 동시 수신, 연결 유지, 골전도 소리 테스트를 사용자가 확인했다. 추가 하드웨어 테스트는 사용자의 요청에 따라 마무리했다.
- 임시 앱은 analyze/테스트 13개/debug APK 빌드·설치 PASS. 프로젝트 센서 33개/backend 관련 28개 테스트는 이전 실행 결과다.
- 연속 스캔/WT901/방향음/RSSI 간격/Android 실행 코드는 임시 앱에만 존재한다. 본 프로젝트에 통합되었거나 실제 서버 E2E가 검증되었다고 표시하지 않는다.
- 이번 브랜치 최신화는 기존 센서 bridge UTC 수정·회귀 테스트·보고서 기록에 한정한다. 임시 앱 소스 및 빌드물은 제외한다.
- 상세 장비/검증/미반영 범위: docs/developer_a/MAIN_BASE_INTEGRATION.md의 '2026-10-23 하드웨어 확인 결과 및 브랜치 최신화 범위'.
- CONFLICT-20261023-안준환-002의 계약/소유권/캐시/LAN 관찰 이슈는 미해결. 실제 HRTF/차량 판별/모든 끊김 실측 완료로 확대하지 않는다.
