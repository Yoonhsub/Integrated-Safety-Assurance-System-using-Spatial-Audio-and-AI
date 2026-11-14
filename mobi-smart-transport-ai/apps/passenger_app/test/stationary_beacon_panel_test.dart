import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/direction_audio_panel.dart';

import 'package:mobi_passenger_app/src/features/hardware_bus/obstacle_cue_input.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/cue_control.dart';

void main() {
  const channel = MethodChannel('mobi.passenger/hardware-tone');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return c.method == 'stop' ? null : {'running': true, 'route': 'mock'};
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  Widget panel(
          {double z = 65,
          double reference = 20,
          String scope = 'MAC-A/session1',
          bool fresh = true,
          bool stale = false,
          int rssi = -85,
          DateTime? beaconSeenAt,
          DateTime Function()? wallClock,
          int Function()? elapsedSensorAgeMs}) =>
      MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: DirectionAudioPanel(
        z: z,
        reference: reference,
        fresh: fresh,
        sensorAgeMs: 0,
        stationaryBeacon: true,
        audioScope: scope,
        beaconName: 'same advertised name',
        beaconRssi: rssi,
        beaconSeenAt: beaconSeenAt ??
            (wallClock?.call() ?? DateTime.now())
                .subtract(Duration(seconds: stale ? 4 : 0)),
        wallClock: wallClock,
        elapsedSensorAgeMs: elapsedSensorAgeMs,
      ))));
  bool enabled(WidgetTester t) =>
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '버스 소리 시작'))
          .onPressed !=
      null;
  Future<void> tap(WidgetTester t, String label) async {
    await t.ensureVisible(find.text(label));
    await t.tap(find.text(label));
    await t.pump();
  }

  testWidgets(
      'explicit calibration, correct turn, same-name other target invalidates',
      (t) async {
    // Direction and identity test: host load must not expire the fixture.
    // The separate stale-input tests below exercise freshness expiration.
    final now = DateTime.utc(2026, 11, 14);
    Widget freshPanel({double z = 65, String scope = 'MAC-A/session1'}) =>
        panel(
            z: z,
            scope: scope,
            wallClock: () => now,
            elapsedSensorAgeMs: () => 0);
    await t.pumpWidget(freshPanel());
    expect(enabled(t), isFalse);
    await tap(t, '목표 비콘을 바라보고 방향 보정');
    expect(enabled(t), isTrue);
    await tap(t, '버스 소리 시작');
    await t.pumpWidget(freshPanel(z: 110));
    await t.pump(const Duration(milliseconds: 200));
    final a = calls.lastWhere((c) => c.method == 'update').arguments as Map;
    expect(a['left'], greaterThan(a['right']));
    expect(a['pattern'], 'target');
    await t.pumpWidget(freshPanel(scope: 'MAC-B/session1'));
    await t.pump();
    expect(calls.last.method, 'stop');
    expect(enabled(t), isFalse);
    await t.pumpWidget(const SizedBox());
  });
  for (final loss in [
    'sensor',
    'beacon',
    'reference',
    'session',
    'reverse',
    'lifecycle',
    'invalid-rssi'
  ]) {
    testWidgets('invalidate $loss without automatic recovery', (t) async {
      await t.pumpWidget(panel());
      await tap(t, '목표 비콘을 바라보고 방향 보정');
      if (loss == 'reverse') {
        await t.ensureVisible(find.byType(SwitchListTile));
        await t.tap(find.byType(SwitchListTile));
        await t.pump();
      } else if (loss == 'lifecycle') {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      } else {
        await tap(t, '버스 소리 시작');
        await t.pumpWidget(panel(
            fresh: loss != 'sensor',
            stale: loss == 'beacon',
            reference: loss == 'reference' ? 21 : 20,
            scope: loss == 'session' ? 'MAC-A/session2' : 'MAC-A/session1',
            rssi: loss == 'invalid-rssi' ? 0 : -85));
        await t.pump();
        expect(calls.last.method, 'stop');
      }
      await t.pumpWidget(panel());
      await t.pump();
      expect(enabled(t), isFalse);
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'stationary beacon loss cannot suppress explicit obstacle warning',
      (t) async {
    Widget warning({required bool stale}) => MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: DirectionAudioPanel(
          z: 0,
          reference: 0,
          fresh: true,
          sensorAgeMs: 0,
          stationaryBeacon: true,
          audioScope: 'target/session',
          beaconRssi: -60,
          beaconSeenAt:
              DateTime.now().subtract(Duration(seconds: stale ? 4 : 0)),
          obstacles: ObstacleCueSnapshot(
              observedAt: Duration.zero,
              observations: const [
                ObstacleCueObservation(
                    id: 'explicit',
                    risk: ObstacleRisk.danger,
                    roadAngleDegrees: 0)
              ]),
          sessionNow: () => Duration.zero,
        ))));
    await t.pumpWidget(warning(stale: false));
    await tap(t, '목표 비콘을 바라보고 방향 보정');
    await tap(t, '안내 소리 시작');
    expect(
        (calls.lastWhere((c) => c.method == 'start').arguments
            as Map)['pattern'],
        'warning');
    final stops = calls.where((c) => c.method == 'stop').length;
    await t.pumpWidget(warning(stale: true));
    await t.pump(const Duration(milliseconds: 200));
    expect(calls.where((c) => c.method == 'stop').length, stops);
    expect(
        (calls.lastWhere((c) => c.method == 'update').arguments
            as Map)['beaconAgeMs'],
        -1);
    expect(find.text('목표 방향 미보정 · 버스 재생 차단'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'fresh packet following lost interval invalidates idle calibration without timer',
      (t) async {
    final firstNow = DateTime.utc(2026, 1, 1, 12);
    Widget source(DateTime seen, DateTime now) => MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: DirectionAudioPanel(
          z: 0,
          reference: 0,
          fresh: true,
          sensorAgeMs: 0,
          stationaryBeacon: true,
          audioScope: 'target/session',
          beaconRssi: -60,
          beaconSeenAt: seen,
          wallClock: () => now,
        ))));
    // Each sample is fresh; the injected timestamps create a deterministic
    // 3 s radio-loss interval without waiting in real time.
    await t.pumpWidget(source(
        firstNow.subtract(const Duration(milliseconds: 2500)), firstNow));
    await tap(t, '목표 비콘을 바라보고 방향 보정');
    expect(enabled(t), isTrue);
    final nextNow = firstNow.add(const Duration(milliseconds: 550));
    await t.pumpWidget(source(nextNow, nextNow));
    await t.pump();
    expect(enabled(t), isFalse);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('fresh sensor after paused UI cannot inherit expired calibration',
      (t) async {
    final now = DateTime.utc(2026, 1, 1, 12);
    var elapsedMs = 0;
    await t.pumpWidget(panel(
        beaconSeenAt: now,
        wallClock: () => now,
        elapsedSensorAgeMs: () => elapsedMs));
    await tap(t, '목표 비콘을 바라보고 방향 보정');
    expect(enabled(t), isTrue);
    // Model a 1 s pause via the injected monotonic clock, without sleeping.
    elapsedMs = 1000;
    await t.pumpWidget(panel(
        beaconSeenAt: now,
        wallClock: () => now,
        elapsedSensorAgeMs: () => elapsedMs));
    await t.pump();
    expect(enabled(t), isFalse);
    expect(calls.where((c) => c.method == 'start'), isEmpty);
    await t.pumpWidget(const SizedBox());
  });
}
