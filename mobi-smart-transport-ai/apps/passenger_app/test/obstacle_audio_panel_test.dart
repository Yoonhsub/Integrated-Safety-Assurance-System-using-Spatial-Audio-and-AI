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
  final epoch = DateTime.utc(2026);
  var beaconAt = DateTime.utc(2026);
  setUp(() {
    now = Duration.zero;
    beaconAt = epoch;
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
        beaconSeenAt: bus ? beaconAt : null,
        wallClock: () => epoch.add(now),
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
  ObstacleCueSnapshot clear() =>
      ObstacleCueSnapshot(observedAt: now, observations: const []);
  bool targetStarted() => calls.any((c) =>
      c.method == 'start' && (c.arguments as Map)['pattern'] == 'target');
  testWidgets('danger requires newer clear frame and newly received beacon',
      (tester) async {
    await tester.pumpWidget(panel(obstacles: risk(), bus: true));
    await start(tester);
    now = const Duration(milliseconds: 100);
    await tester.pumpWidget(panel(obstacles: clear(), bus: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls.last.method, 'stop');
    expect(targetStarted(), isFalse);
    // Explicit start cannot bypass the old beacon gate.
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '안내 소리 시작'))
            .onPressed,
        isNull);
    beaconAt = epoch.add(now);
    await tester.pumpWidget(panel(obstacles: clear(), bus: true));
    await start(tester);
    expect(targetStarted(), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final loss in ['missing', 'expired', 'future', 'older']) {
    testWidgets('camera $loss stops approach; old beacon cannot restart',
        (tester) async {
      now = const Duration(milliseconds: 100);
      await tester.pumpWidget(panel(obstacles: clear(), bus: true));
      await start(tester);
      expect(targetStarted(), isTrue);
      calls.clear();
      final previous = clear();
      now = const Duration(milliseconds: 2100);
      final lost = loss == 'missing'
          ? null
          : loss == 'expired'
              ? previous
              : ObstacleCueSnapshot(
                  observedAt: loss == 'future'
                      ? const Duration(seconds: 3)
                      : Duration.zero,
                  observations: const []);
      await tester.pumpWidget(panel(obstacles: lost, bus: true));
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls.last.method, 'stop');
      now += const Duration(milliseconds: 1);
      await tester.pumpWidget(panel(obstacles: clear(), bus: true));
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, '안내 소리 시작'))
              .onPressed,
          isNull);
      expect(targetStarted(), isFalse);
      beaconAt = epoch.add(now);
      await tester.pumpWidget(panel(obstacles: clear(), bus: true));
      await start(tester);
      expect(targetStarted(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('sensor loss stops obstacle even without beacon dependency',
      (tester) async {
    await tester.pumpWidget(panel(obstacles: risk()));
    await start(tester);
    await tester.pumpWidget(panel(obstacles: risk(), fresh: false));
    await tester.pump();
    expect(calls.last.method, 'stop');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('missing shared clock cannot start a warning', (tester) async {
    await tester.pumpWidget(panel(obstacles: risk(), clock: false));
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '안내 소리 시작'))
            .onPressed,
        isNull);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'rear obstacle uses spatial azimuth and never displays a front cue',
      (tester) async {
    await tester.pumpWidget(panel(obstacles: risk(angle: 180)));
    await start(tester);
    final args = calls.lastWhere((c) => c.method == 'start').arguments as Map;
    expect((args['azimuthDegrees'] as num).abs(), 180);
    expect(args['left'], args['right']);
    expect(args['pattern'], 'warning');
    expect(args['beaconAgeMs'], -1);
    expect(find.text('후방 장애물 · 공간 경고음'), findsOneWidget);
    expect(find.text('출력 Cue: FRONT'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'rear source follows head turn through side to front without restarting',
      (tester) async {
    final obstacle = risk(angle: 180);
    await tester.pumpWidget(panel(obstacles: obstacle));
    await start(tester);
    await tester.pumpWidget(panel(obstacles: obstacle, yaw: 90));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
        calls
            .lastWhere((c) => c.method == 'update')
            .arguments['azimuthDegrees'],
        90);
    await tester.pumpWidget(panel(obstacles: obstacle, yaw: 180));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
        calls
            .lastWhere((c) => c.method == 'update')
            .arguments['azimuthDegrees'],
        0);
    expect(calls.where((c) => c.method == 'start').length, 1);
    expect(find.text('후방 장애물 · 공간 경고음'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
