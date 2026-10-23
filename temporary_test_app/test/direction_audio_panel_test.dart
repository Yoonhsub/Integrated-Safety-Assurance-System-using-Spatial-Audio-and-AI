import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_ble_temp/direction_audio_panel.dart';

void main() {
  const channel = MethodChannel('mobi.temp/tone');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'stop'
              ? null
              : {'running': true, 'route': 'Test headset'};
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Widget panel({
    double z = 0,
    bool fresh = true,
    int rssi = -85,
    DateTime? seen,
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: DirectionAudioPanel(
          key: const ValueKey('tone'),
          z: z,
          reference: 0,
          fresh: fresh,
          sensorAgeMs: 0,
          beaconRssi: rssi,
          beaconSeenAt: seen ?? DateTime.now(),
        ),
      ),
    ),
  );

  Future<void> start(WidgetTester tester) async {
    await tester.ensureVisible(find.text('방향음 시작'));
    await tester.tap(find.text('방향음 시작'));
    await tester.pump();
  }

  testWidgets('rotation and stronger RSSI update different output parameters', (
    tester,
  ) async {
    await tester.pumpWidget(panel());
    await start(tester);
    final initial =
        calls.firstWhere((c) => c.method == 'start').arguments as Map;
    expect(initial['intervalMs'], 1400);
    expect(initial['left'], closeTo(initial['right'], 1e-9));
    await tester.pumpWidget(panel(z: 90, rssi: -45));
    await tester.pump(const Duration(milliseconds: 200));
    final update =
        calls.lastWhere((c) => c.method == 'update').arguments as Map;
    expect(update['intervalMs'], 220);
    expect(update['left'], closeTo(1, 1e-9));
    expect(update['right'], closeTo(0, 1e-9));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last.method, 'stop');
  });

  testWidgets('sensor loss and stale beacon stop the tone', (tester) async {
    await tester.pumpWidget(panel());
    await start(tester);
    await tester.pumpWidget(panel(fresh: false));
    await tester.pump();
    expect(calls.last.method, 'stop');
    await tester.pumpWidget(panel());
    await start(tester);
    await tester.pumpWidget(
      panel(seen: DateTime.now().subtract(const Duration(seconds: 4))),
    );
    await tester.pump();
    expect(calls.last.method, 'stop');
    expect(
      (tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '방향음 시작'),
      )).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'rear target stops native output instead of playing a front cue',
    (tester) async {
      await tester.pumpWidget(panel());
      await start(tester);
      await tester.pumpWidget(panel(z: 180));
      await tester.pump();
      expect(calls.last.method, 'stop');
      expect(find.text('후방 목표 · 재생 중지'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'live tone holds front near boundary and changes after deadband',
    (tester) async {
      await tester.pumpWidget(panel());
      await start(tester);
      await tester.pumpWidget(panel(z: -24));
      await tester.pump(const Duration(milliseconds: 200));
      final held =
          calls.lastWhere((c) => c.method == 'update').arguments as Map;
      expect(held['left'], closeTo(held['right'], 1e-9));
      await tester.pumpWidget(panel(z: -26));
      await tester.pump(const Duration(milliseconds: 200));
      final changed =
          calls.lastWhere((c) => c.method == 'update').arguments as Map;
      expect(
        changed['right'] as double,
        greaterThan(changed['left'] as double),
      );
      expect(calls.where((c) => c.method == 'start'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
