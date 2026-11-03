import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

ScanResult observation(String id, DateTime stamp, {int rssi = -55}) =>
    ScanResult(
      device: BluetoothDevice.fromId(id),
      advertisementData: AdvertisementData(
          advName: 'SHARED_NAME',
          txPowerLevel: null,
          appearance: null,
          connectable: false,
          manufacturerData: {},
          serviceData: {},
          serviceUuids: []),
      rssi: rssi,
      timeStamp: stamp,
    );

void main() {
  test(
      'stop waits for delayed start, releases resources once, and permits restart',
      () async {
    final started = Completer<void>();
    final source = StreamController<List<ScanResult>>.broadcast();
    var stops = 0;
    var starts = 0;
    final scanner = FlutterBlueBeaconScanner(
        scanResults: source.stream,
        startScan: () {
          starts++;
          return started.future;
        },
        stopScan: () async {
          stops++;
        });
    final first = scanner.scan().toList();
    await Future<void>.delayed(Duration.zero);
    final stopping = scanner.stop();
    expect(stops, 0);
    started.complete();
    await stopping;
    await first;
    expect(stops, 1);
    final second = scanner.scan().toList();
    await Future<void>.delayed(Duration.zero);
    await scanner.stop();
    await second;
    expect(starts, 2);
    expect(stops, 2);
    await source.close();
  });

  test('payload serialization preserves observation instant in UTC', () {
    final observed = DateTime.parse('2026-10-11T09:00:00+09:00');
    final signal = const BeaconDistanceEstimator()
        .buildSignal(beaconId: 'A', rssi: -55, lastDetectedAt: observed);
    final payload = BeaconIngestPayload.fromSignal(
        signal: signal, sessionId: 's', deviceId: 'd');
    expect(payload.toJson()['timestamp'], '2026-10-11T00:00:00.000Z');
    expect(payload.busId, isNull);
  });

  test('cached lists preserve callback time and do not replay other devices',
      () async {
    var now = DateTime.utc(2026, 10, 11);
    final start = now;
    final source = StreamController<List<ScanResult>>();
    var stops = 0;
    final scanner = FlutterBlueBeaconScanner(
      scanResults: source.stream,
      now: () => now,
      startScan: () async {},
      stopScan: () async {
        stops++;
      },
    );
    final received = <BeaconSignal>[];
    final done = Completer<void>();
    final subscription =
        scanner.scan().listen(received.add, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    final a = observation('A', start);
    source.add([a]);
    await Future<void>.delayed(Duration.zero);
    now = start.add(const Duration(seconds: 1));
    source.add([a, observation('B', now)]);
    await Future<void>.delayed(Duration.zero);
    source.add([
      observation('A', start.subtract(const Duration(seconds: 1))),
      observation('B', now)
    ]);
    await Future<void>.delayed(Duration.zero);
    now = start.add(const Duration(seconds: 2));
    source.add([
      observation('A', now),
      observation('B', now.add(const Duration(seconds: 1)))
    ]);
    await Future<void>.delayed(Duration.zero);
    await scanner.stop();
    await done.future.timeout(const Duration(seconds: 2));
    expect(received.map((e) => e.beaconId), ['A', 'B', 'A']);
    expect(received.first.lastDetectedAt, start);
    expect(received.last.lastDetectedAt, now);
    expect(stops, 1);
    await subscription.cancel();
    await source.close();
  });

  test('silent scanner completes at timeout without another callback',
      () async {
    final source = StreamController<List<ScanResult>>();
    var stops = 0;
    final scanner = FlutterBlueBeaconScanner(
        scanResults: source.stream,
        startScan: () async {},
        stopScan: () async {
          stops++;
        },
        scanTimeout: const Duration(milliseconds: 20));
    expect(await scanner.scan().toList().timeout(const Duration(seconds: 2)),
        isEmpty);
    expect(stops, 1);
    expect(scanner.isScanning, isFalse);
    await source.close();
  });

  test('scan error propagates and stops the platform', () async {
    final source = StreamController<List<ScanResult>>();
    var stops = 0;
    final scanner = FlutterBlueBeaconScanner(
        scanResults: source.stream,
        startScan: () async {
          source.addError(StateError('radio failed'));
        },
        stopScan: () async {
          stops++;
        });
    await expectLater(scanner.scan().toList(), throwsStateError);
    expect(stops, 1);
    await source.close();
  });

  test(
      'old and future signals are not fresh; reverse order cannot change history',
      () {
    final now = DateTime.utc(2026, 10, 11);
    const estimator = BeaconDistanceEstimator();
    final fresh =
        estimator.buildSignal(beaconId: 'A', rssi: -60, lastDetectedAt: now);
    final future =
        fresh.copyWith(lastDetectedAt: now.add(const Duration(seconds: 1)));
    expect(future.wasDetectedWithin(const Duration(seconds: 5), now: now),
        isFalse);
    final tracker = BeaconProximityTracker();
    tracker.addSignal(fresh, now: now);
    final old = fresh.copyWith(
        rssi: -100, lastDetectedAt: now.subtract(const Duration(seconds: 1)));
    expect(tracker.addSignal(old, now: now).isStale, isTrue);
    expect(tracker.addSignal(fresh, now: now).isStale, isTrue);
    final next =
        fresh.copyWith(lastDetectedAt: now.add(const Duration(seconds: 1)));
    expect(tracker.addSignal(next, now: next.lastDetectedAt).previousSignal,
        fresh);
    final adapter = ProximityEventStreamAdapter(scanner: MockBeaconScanner([]));
    expect(
        adapter.eventsForSignal(fresh,
            now: now.add(const Duration(seconds: 20))),
        isEmpty);
  });
}
