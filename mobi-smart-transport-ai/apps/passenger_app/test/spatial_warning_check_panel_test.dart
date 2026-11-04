import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/direction_audio_panel.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/spatial_warning_check_panel.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/wit_sensor_panel.dart';

void main() {
  testWidgets(
      'listening check replaces regular output and preserves sensor state',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: WitSensorPanel(ensureReady: () async => false),
    ))));
    final sensor = tester.state(find.byType(WitSensorPanel));
    final toggle = find.text('공간 경고음 청취 확인 (검증용)');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(SpatialWarningCheckPanel), findsOneWidget);
    expect(find.byType(DirectionAudioPanel), findsOneWidget);
    expect(
        identical(tester.state(find.byType(WitSensorPanel)), sensor), isTrue);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(SpatialWarningCheckPanel), findsNothing);
    expect(find.byType(DirectionAudioPanel), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('comparison uses real spatial output path and unmount stops it',
      (tester) async {
    const channel = MethodChannel('mobi.passenger/hardware-tone');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return call.method == 'stop'
          ? null
          : {'running': true, 'route': 'test headset'};
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: SpatialWarningCheckPanel(
          z: 0, reference: 0, fresh: true, sensorAgeMs: 0),
    ))));
    await tester.tap(find.byType(DropdownButton<double>));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('정후방 · 180°').last);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.ensureVisible(find.text('안내 소리 시작'));
    await tester.tap(find.text('안내 소리 시작'));
    await tester.pump();
    final args =
        calls.lastWhere((call) => call.method == 'start').arguments as Map;
    expect((args['azimuthDegrees'] as num).abs(), 180);
    expect(args['beaconAgeMs'], -1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last.method, 'stop');
  });
}
