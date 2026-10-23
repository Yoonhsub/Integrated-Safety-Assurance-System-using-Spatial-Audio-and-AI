import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_ble_temp/main.dart';
import 'package:mobi_ble_temp/wit_sensor_panel.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  testWidgets('scan start and timeout preserve the sensor panel state', (
    tester,
  ) async {
    const channel = MethodChannel('mobi.temp/permissions');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => {'granted': true, 'locationEnabled': true},
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final scanner = _ControlledScanner();
    await tester.pumpWidget(
      MaterialApp(home: BleTestPage(scannerFactory: (_) => scanner)),
    );
    final sensorBefore = tester.state(find.byType(WitSensorPanel));
    await tester.tap(find.text('15초 스캔'));
    await tester.pump();
    await tester.pump();
    expect(
      identical(tester.state(find.byType(WitSensorPanel)), sensorBefore),
      isTrue,
      reason: 'Adding the countdown must not dispose a live sensor connection',
    );
    scanner.controller.add(
      BeaconSignal(
        beaconId: beaconA,
        rssi: -55,
        estimatedDistanceMeters: 2,
        signalLevel: BeaconSignalLevel.close,
        lastDetectedAt: DateTime.now(),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(
      identical(tester.state(find.byType(WitSensorPanel)), sensorBefore),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(
      identical(tester.state(find.byType(WitSensorPanel)), sensorBefore),
      isTrue,
      reason: 'Removing the countdown must also preserve sensor state',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'shows separate beacon identifiers without scanning automatically',
    (tester) async {
      await tester.pumpWidget(const BleTestApp());
      expect(find.text(witSensorMac), findsOneWidget);
      expect(find.text('아직 각도를 수신하지 않았습니다.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(beaconA),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(beaconA), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(beaconB),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(beaconB), findsOneWidget);
      expect(find.byType(WitSensorPanel, skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _ControlledScanner implements BeaconScanner {
  final controller = StreamController<BeaconSignal>();
  @override
  bool isScanning = false;
  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) {
    isScanning = true;
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    isScanning = false;
    await controller.close();
  }
}
