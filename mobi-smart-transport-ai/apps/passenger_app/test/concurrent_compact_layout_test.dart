import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/concurrent_hardware_test_page.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'concurrent_hardware_control_test.dart' as fixture;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final size in [const Size(360, 800), const Size(412, 915)]) {
    testWidgets('two retained views fit $size without main scrolling',
        (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final engine = SpatialVerificationEngine(fixture.Output(), fixture.Tts());
      await t.pumpWidget(MaterialApp(
          home: ConcurrentHardwareTestPage(
              engine: engine, ensurePermission: () async => true)));
      expect(t.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.text('센서 연결'), findsOneWidget);
      expect(find.text('카메라 시작'), findsNothing);
      await t.tap(find.textContaining('2 카메라'));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.text('카메라 시작'), findsOneWidget);
      expect(find.text('센서 연결'), findsNothing);
      expect(t.getRect(find.text('자세히 듣기')).bottom, lessThan(size.height));
      await t.tap(find.textContaining('1 버스·WT'));
      await t.pump();
      expect(find.text('센서 연결'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    });
  }
  testWidgets(
      'large text offers explicit enlarged controls, not clipped main page',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final engine = SpatialVerificationEngine(fixture.Output(), fixture.Tts());
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!),
        home: ConcurrentHardwareTestPage(
            engine: engine, ensurePermission: () async => true)));
    expect(t.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.text('확대 보기'), findsNWidgets(2));
    await t.tap(find.text('확대 보기').first);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(t.takeException(), isNull);
    await t.tap(find.text('닫기'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
  testWidgets('pairing keyboard inset does not resize retained hardware views',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetViewInsets);
    final engine = SpatialVerificationEngine(fixture.Output(), fixture.Tts());
    await t.pumpWidget(MaterialApp(
        home: ConcurrentHardwareTestPage(
            engine: engine, ensurePermission: () async => true)));
    await t.pumpAndSettle();
    await t.tap(find.text('번호·MAC 설정'));
    await t.pumpAndSettle();
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.ensureVisible(find.widgetWithText(
        TextField, '실제 Android 비콘 MAC (예: AA:BB:CC:DD:EE:FF)'));
    expect(t.takeException(), isNull);
    t.view.resetViewInsets();
    await t.pumpAndSettle();
    await t.tap(find.text('완료'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
}
