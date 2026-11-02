import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/cue_control.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/obstacle_cue_input.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/direction_audio_panel.dart';

void main() {
  const channel = MethodChannel('mobi.passenger/hardware-tone');
  final calls = <MethodCall>[];
  var now = Duration.zero;
  setUp(() {
    now = Duration.zero;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'stop'
          ? null
          : {'running': true, 'route': 'test headset'};
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  ObstacleCueSnapshot risk({double angle = 45}) =>
      ObstacleCueSnapshot(observedAt: Duration.zero, observations: [
        ObstacleCueObservation(
            id: 'obstacle', risk: ObstacleRisk.danger, roadAngleDegrees: angle),
      ]);
  Widget panel(
          {ObstacleCueSnapshot? obstacles,
          bool bus = false,
          bool fresh = true,
          bool clock = true,
          double yaw = 0}) =>
      MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: DirectionAudioPanel(
        key: const ValueKey('output'),
        z: yaw,
        reference: 0,
        fresh: fresh,
        sensorAgeMs: 0,
        obstacles: obstacles,
        sessionNow: clock ? () => now : null,
        beaconRssi: bus ? -55 : null,
        beaconSeenAt: bus ? DateTime.now() : null,
        busAngle: 0,
        busEnabled: bus,
      ))));
  Future<void> start(WidgetTester tester) async {
    await tester.ensureVisible(find.text('안내 소리 시작'));
    await tester.tap(find.text('안내 소리 시작'));
    await tester.pump();
  }

  testWidgets(
      'obstacle sounds without beacon or bus enabled and follows head pose',
      (tester) async {
    await tester.pumpWidget(panel(obstacles: risk(), yaw: 45));
    await start(tester);
    final args = calls.lastWhere((c) => c.method == 'start').arguments as Map;
    expect(args['pattern'], 'warning');
    expect(args['beaconAgeMs'], -1);
    expect(args['left'], closeTo(args['right'], 1e-9));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('expired obstacle stops output without a bus fallback',
      (tester) async {
    final snapshot = risk();
    await tester.pumpWidget(panel(obstacles: snapshot));
    await start(tester);
    now = const Duration(seconds: 2);
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls.last.method, 'stop');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('disappearing obstacle resumes valid bus with beacon watchdog',
      (tester) async {
    await tester.pumpWidget(panel(obstacles: risk(), bus: true));
    await start(tester);
    await tester.pumpWidget(panel(bus: true));
    await tester.pump(const Duration(milliseconds: 200));
    final args = calls.lastWhere((c) => c.method == 'start').arguments as Map;
    expect(args['pattern'], 'target');
    expect(args['beaconAgeMs'], greaterThanOrEqualTo(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('sensor loss stops obstacle even without beacon dependency',
      (tester) async {
    await tester.pumpWidget(panel(obstacles: risk()));
    await start(tester);
    await tester.pumpWidget(panel(obstacles: risk(), fresh: false));
    await tester.pump();
    expect(calls.last.method, 'stop');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'missing shared clock and rear hazard cannot start a false front warning',
      (tester) async {
    await tester.pumpWidget(panel(obstacles: risk(), clock: false));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '안내 소리 시작'))
            .onPressed,
        isNull);
    await tester.pumpWidget(panel(obstacles: risk(angle: 180)));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '안내 소리 시작'))
            .onPressed,
        isNull);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
