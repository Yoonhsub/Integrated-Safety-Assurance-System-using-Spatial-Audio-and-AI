import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/safety_integration_check_page.dart';

void main() {
  const channel = MethodChannel('mobi.passenger/hardware-tone');
  final calls = <MethodCall>[];
  var now = Duration.zero;
  setUp(() {
    calls.clear();
    now = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return c.method == 'stop' ? null : {'running': true, 'route': 'test'};
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  Future<void> tap(WidgetTester t, String label) async {
    final f = find.text(label);
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pump();
  }

  void blocked(WidgetTester t) => expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '안내 소리 시작'))
          .onPressed,
      isNull);
  String pattern() =>
      calls.lastWhere((c) => c.method == 'start').arguments['pattern'];
  testWidgets('hazard preempts; old beacon blocked; fresh manual restart',
      (t) async {
    await t.pumpWidget(
        MaterialApp(home: SafetyIntegrationCheckPage(elapsed: () => now)));
    expect(find.textContaining('모의 입력 전용'), findsOneWidget);
    await tap(t, '새 비콘 수신 (모의)');
    await tap(t, '안내 소리 시작');
    expect(pattern(), 'target');
    now = const Duration(milliseconds: 200);
    await tap(t, '고위험 발생 (모의)');
    await t.pump(const Duration(milliseconds: 200));
    expect(pattern(), 'warning');
    final count = calls.where((c) => c.method == 'start').length;
    now = const Duration(milliseconds: 400);
    await tap(t, '위험 해제 (모의)');
    await t.pump(const Duration(milliseconds: 200));
    expect(calls.last.method, 'stop');
    await tap(t, '과거 비콘 재사용 (모의)');
    blocked(t);
    now = const Duration(milliseconds: 600);
    await tap(t, '새 비콘 수신 (모의)');
    expect(calls.where((c) => c.method == 'start').length, count);
    await tap(t, '안내 소리 시작');
    expect(pattern(), 'target');
    await t.pumpWidget(const SizedBox.shrink());
    expect(calls.last.method, 'stop');
  });
  testWidgets('camera loss recovery and beacon expiry', (t) async {
    await t.pumpWidget(
        MaterialApp(home: SafetyIntegrationCheckPage(elapsed: () => now)));
    await tap(t, '새 비콘 수신 (모의)');
    await tap(t, '안내 소리 시작');
    now = const Duration(milliseconds: 200);
    await tap(t, '카메라 입력 상실 (모의)');
    await t.pump(const Duration(milliseconds: 200));
    expect(calls.last.method, 'stop');
    now = const Duration(milliseconds: 400);
    await tap(t, '카메라 입력 복구 (모의)');
    blocked(t);
    now = const Duration(milliseconds: 600);
    await tap(t, '새 비콘 수신 (모의)');
    await tap(t, '안내 소리 시작');
    expect(pattern(), 'target');
    await tap(t, '비콘 신호 상실 (모의)');
    now = const Duration(milliseconds: 3600);
    await t.pump(const Duration(milliseconds: 200));
    await t.pump();
    expect(calls.last.method, 'stop');
    await t.pumpWidget(const SizedBox.shrink());
  });
}
