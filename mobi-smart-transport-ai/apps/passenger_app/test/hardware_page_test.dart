import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/hardware_bus_page.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/wit_sensor_panel.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  testWidgets('scan start and timeout preserve the sensor panel state', (
    tester,
  ) async {
    const channel = MethodChannel('mobi.passenger/hardware-permissions');
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
      MaterialApp(home: HardwareBusPage(scannerFactory: (_) => scanner)),
    );
    final sensorBefore = tester.state(find.byType(WitSensorPanel));
    await tester.tap(find.text('버스 탐색 시작 (5분)'));
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
    await tester.pump(const Duration(minutes: 5));
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
      await tester.pumpWidget(const MaterialApp(home: HardwareBusPage()));
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
  testWidgets(
      'two nearby buses retain selected target; stronger wrong bus warns',
      (tester) async {
    const permissions = MethodChannel('mobi.passenger/hardware-permissions');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissions, (_) async => {'granted': true, 'locationEnabled': true});
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null));
    final scanner = _ControlledScanner();
    await tester.pumpWidget(
        MaterialApp(home: HardwareBusPage(scannerFactory: (_) => scanner)));
    await tester.tap(find.text('버스 탐색 시작 (5분)'));
    await tester.pump();
    await tester.pump();
    void emit(String id, int rssi) => scanner.controller.add(BeaconSignal(
        beaconId: id,
        rssi: rssi,
        estimatedDistanceMeters: 1,
        signalLevel: BeaconSignalLevel.close,
        lastDetectedAt: DateTime.now()));
    emit(beaconA, -55);
    emit(beaconB, -56);
    await tester.pump();
    expect(tester.widget<WitSensorPanel>(find.byType(WitSensorPanel)).warning,
        isFalse);
    emit(beaconB, -40);
    await tester.pump();
    expect(tester.widget<WitSensorPanel>(find.byType(WitSensorPanel)).warning,
        isTrue);
    tester
        .widget<DropdownButton<String>>(
            find.byType(DropdownButton<String>).first)
        .onChanged!(beaconB);
    await tester.pump();
    expect(tester.widget<WitSensorPanel>(find.byType(WitSensorPanel)).warning,
        isFalse);
    expect(
        tester.widget<WitSensorPanel>(find.byType(WitSensorPanel)).beaconName,
        contains('511'));
    await tester.pumpWidget(const SizedBox.shrink());
  });
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
