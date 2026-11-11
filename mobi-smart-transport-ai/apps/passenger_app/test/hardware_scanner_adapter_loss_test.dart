import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/continuous_beacon_scanner.dart';

void main() {
  for (final pendingStart in [false, true]) {
    test('adapter OFF ends scan, including pending start=$pendingStart',
        () async {
      final adapters = StreamController<BluetoothAdapterState>();
      final results = StreamController<List<ScanResult>>();
      final start = Completer<void>();
      var stopCalls = 0;
      final errors = <Object>[];
      final done = Completer<void>();
      final scanner = ContinuousBeaconScanner(
        beaconIdResolver: (_) => 'unused',
        scanTimeout: const Duration(minutes: 5),
        adapterStates: adapters.stream,
        scanResults: results.stream,
        startScan: () => pendingStart ? start.future : Future.value(),
        stopScan: () async {
          stopCalls++;
        },
      );
      final subscription = scanner.scan().listen(
            (_) => fail('No radio packets were supplied'),
            onError: (Object e) => errors.add(e),
            onDone: done.complete,
          );
      await Future<void>.delayed(Duration.zero);
      adapters.add(BluetoothAdapterState.on);
      adapters.add(BluetoothAdapterState.turningOff);
      adapters.add(BluetoothAdapterState.off);
      await done.future.timeout(const Duration(seconds: 2));
      expect(scanner.isScanning, isFalse);
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('Bluetooth'));
      expect(stopCalls, greaterThanOrEqualTo(1));
      if (pendingStart) {
        start.complete();
        await Future<void>.delayed(Duration.zero);
        expect(scanner.isScanning, isFalse);
      }
      await subscription.cancel();
      await scanner.stop();
      await adapters.close();
      await results.close();
    });
  }
}
