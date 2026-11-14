import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/hardware_test_settings.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/concurrent_hardware_test_page.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'concurrent_hardware_control_test.dart' as fixture;

class SettingsFake implements HardwareTestSettingsStore {
  BusTestPairing? bus;
  String? wit;
  bool failLoad = false, failSave = false;
  Completer<BusTestPairing?>? loading;
  @override
  Future<BusTestPairing?> loadBus() async {
    if (failLoad) throw StateError('load');
    if (loading != null) return await loading!.future;
    return bus;
  }

  @override
  Future<void> saveBus(BusTestPairing value) async {
    if (failSave) throw StateError('save');
    bus = value;
  }

  @override
  Future<void> resetBus() async {
    if (failSave) throw StateError('save');
    bus = null;
  }

  @override
  Future<String?> loadWit() async => wit;
  @override
  Future<void> saveWit(String value) async {
    wit = value;
  }

  @override
  Future<void> resetWit() async {
    wit = null;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
      'validated identifiers roundtrip as one bus record and independent WT key',
      () async {
    final store = SharedPreferencesHardwareTestSettingsStore();
    expect(BusTestPairing.parse('502', 'advertised-name'), isNull);
    expect(HardwareTestSettings.normalizeMac('notmac'), isNull);
    final value = BusTestPairing.parse('502', 'aa-bb-cc-dd-ee-ff')!;
    await store.saveBus(value);
    await store.saveWit('11:22:33:44:55:66');
    final restored = await store.loadBus();
    expect(restored!.routeNo, '502');
    expect(restored.mac, 'AA:BB:CC:DD:EE:FF');
    await expectLater(store.saveWit('bad'), throwsFormatException);
    expect(await store.loadWit(), '11:22:33:44:55:66');
    await store.resetBus();
    expect(await store.loadBus(), isNull);
    expect(await store.loadWit(), '11:22:33:44:55:66');
    await store.resetWit();
    expect(await store.loadWit(), isNull);
  });
  test(
      'corrupt persisted configuration fails explicitly rather than fabricating a mapping',
      () async {
    SharedPreferences.setMockInitialValues({
      SharedPreferencesHardwareTestSettingsStore.busKey:
          '{"route":"502","mac":"bad"}'
    });
    await expectLater(SharedPreferencesHardwareTestSettingsStore().loadBus(),
        throwsFormatException);
  });
  Future<void> mount(WidgetTester t, SettingsFake store) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        home: ConcurrentHardwareTestPage(
            engine: SpatialVerificationEngine(fixture.Output(), fixture.Tts()),
            settingsStore: store,
            ensurePermission: () async => true,
            sensorBuilder: (_) => const SizedBox(),
            cameraBuilder: (_, __, ___, ____) => const SizedBox())));
  }

  testWidgets('loading blocks scan and late load after disposal is ignored',
      (t) async {
    final store = SettingsFake()..loading = Completer<BusTestPairing?>();
    await mount(t, store);
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '버스 탐색 시작'))
            .onPressed,
        isNull);
    expect(find.text('저장 설정 불러오는 중'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    store.loading!.complete(BusTestPairing.parse('502', 'AA:BB:CC:DD:EE:FF'));
    await t.pump();
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'explicit save normalizes, write error keeps runtime pairing, reset is explicit',
      (t) async {
    final store = SettingsFake();
    await mount(t, store);
    await t.pumpAndSettle();
    await t.tap(find.text('번호·MAC 설정'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '시연 버스 번호'), '502');
    await t.enterText(
        find.widgetWithText(
            TextField, '실제 Android 비콘 MAC (예: AA:BB:CC:DD:EE:FF)'),
        'aa-bb-cc-dd-ee-ff');
    await t.tap(find.text('저장'));
    await t.pumpAndSettle();
    expect(store.bus!.mac, 'AA:BB:CC:DD:EE:FF');
    store.failSave = true;
    await t.enterText(find.widgetWithText(TextField, '시연 버스 번호'), '511');
    await t.tap(find.text('저장'));
    await t.pumpAndSettle();
    expect(store.bus!.routeNo, '502');
    expect(find.textContaining('저장 변경 실패'), findsOneWidget);
    store.failSave = false;
    await t.tap(find.text('저장 초기화'));
    await t.pumpAndSettle();
    expect(store.bus, isNull);
    await t.tap(find.text('완료'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
  testWidgets('load failure has actionable feedback and no automatic scan',
      (t) async {
    await mount(t, SettingsFake()..failLoad = true);
    await t.pumpAndSettle();
    expect(find.textContaining('저장 설정 읽기 실패'), findsOneWidget);
    expect(find.text('버스 시연 · 대기'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
}
