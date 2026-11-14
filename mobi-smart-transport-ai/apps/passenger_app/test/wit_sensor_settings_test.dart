import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/wit_sensor_panel.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/hardware_test_settings.dart';

class Store extends HardwareTestSettingsStore {
  String? value;
  bool fail = false, failLoad = false;
  int writes = 0;
  Completer<String?>? loading;
  @override
  Future<String?> loadWit() async {
    if (failLoad) throw StateError('read failed');
    return loading == null ? value : await loading!.future;
  }

  @override
  Future<void> saveWit(String address) async {
    if (fail) throw StateError('storage unavailable');
    writes++;
    value = address;
  }

  @override
  Future<void> resetWit() async {
    if (fail) throw StateError('storage unavailable');
    value = null;
  }

  @override
  Future<BusTestPairing?> loadBus() async => null;
  @override
  Future<void> saveBus(BusTestPairing pairing) async {}
  @override
  Future<void> resetBus() async {}
}

Widget panel(Store store,
        {bool allow = true, Future<bool> Function()? ready}) =>
    MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WitSensorPanel(
                    stateOnly: true,
                    allowConfiguration: allow,
                    settingsStore: store,
                    ensureReady: ready ?? () async => false))));
Future<void> open(WidgetTester t) async {
  await t.ensureVisible(find.text('WT 주소 설정'));
  await t.tap(find.text('WT 주소 설정'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('WT configuration remains opt in and performs no default load',
      (t) async {
    final store = Store()..value = 'AA:BB:CC:DD:EE:01';
    await t.pumpWidget(panel(store, allow: false));
    expect(find.text('WT 주소 설정'), findsNothing);
    expect(find.text(witSensorMac), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('load blocks connect and disposal safely ignores pending load',
      (t) async {
    final store = Store()..loading = Completer<String?>();
    await t.pumpWidget(panel(store));
    final button =
        t.widget<FilledButton>(find.widgetWithText(FilledButton, '센서 연결'));
    expect(button.onPressed, isNull);
    await t.pumpWidget(const SizedBox());
    store.loading!.complete('AA:BB:CC:DD:EE:01');
    await t.pump();
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'valid save normalizes persists and reset restores default without connecting',
      (t) async {
    final store = Store();
    var connects = 0;
    await t.pumpWidget(panel(store, ready: () async {
      connects++;
      return false;
    }));
    await t.pump();
    await open(t);
    await t.enterText(find.byType(TextField), 'bad');
    await t.tap(find.text('저장'));
    await t.pump();
    expect(store.writes, 0);
    expect(find.textContaining('형식의 MAC 주소'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'aa:bb:cc:dd:ee:01');
    await t.tap(find.text('저장'));
    await t.pumpAndSettle();
    expect(store.value, 'AA:BB:CC:DD:EE:01');
    expect(find.text('AA:BB:CC:DD:EE:01'), findsOneWidget);
    expect(connects, 0);
    await open(t);
    await t.tap(find.text('기본값 복원'));
    await t.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.text(witSensorMac), findsOneWidget);
    expect(connects, 0);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'save failure retains active address and connecting locks configuration',
      (t) async {
    final store = Store()..fail = true;
    final ready = Completer<bool>();
    await t.pumpWidget(panel(store, ready: () => ready.future));
    await t.pump();
    await open(t);
    await t.enterText(find.byType(TextField), 'AA:BB:CC:DD:EE:01');
    await t.tap(find.text('저장'));
    await t.pump();
    expect(find.textContaining('기존 주소를 유지합니다'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(find.text(witSensorMac), findsOneWidget);
    await t.ensureVisible(find.text('센서 연결'));
    await t.tap(find.text('센서 연결'));
    await t.pump();
    final settings = t.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'WT 주소 설정'));
    expect(settings.onPressed, isNull);
    ready.complete(false);
    await t.pump();
    await t.pumpWidget(const SizedBox());
  });
  for (final corrupt in [false, true]) {
    testWidgets(
        'invalid or unreadable WT settings block connect until explicit reset: $corrupt',
        (t) async {
      final store = Store()
        ..failLoad = !corrupt
        ..value = corrupt ? 'bad' : null;
      await t.pumpWidget(panel(store));
      await t.pump();
      expect(
          t
              .widget<FilledButton>(find.widgetWithText(FilledButton, '센서 연결'))
              .onPressed,
          isNull);
      expect(
          t
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'WT 주소 설정'))
              .onPressed,
          isNotNull);
      await open(t);
      await t.tap(find.text('기본값 복원'));
      await t.pumpAndSettle();
      expect(
          t
              .widget<FilledButton>(find.widgetWithText(FilledButton, '센서 연결'))
              .onPressed,
          isNotNull);
      expect(find.text(witSensorMac), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'read failure remains locked after failed reset then valid save recovers',
      (t) async {
    final store = Store()
      ..failLoad = true
      ..fail = true;
    await t.pumpWidget(panel(store));
    await t.pump();
    await open(t);
    await t.tap(find.text('기본값 복원'));
    await t.pump();
    expect(find.textContaining('기존 주소를 유지합니다'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '센서 연결'))
            .onPressed,
        isNull);
    store.fail = false;
    await open(t);
    await t.enterText(find.byType(TextField), 'AA:BB:CC:DD:EE:02');
    await t.tap(find.text('저장'));
    await t.pumpAndSettle();
    expect(store.value, 'AA:BB:CC:DD:EE:02');
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '센서 연결'))
            .onPressed,
        isNotNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'absent saved WT address keeps the visible legacy default connectable',
      (t) async {
    await t.pumpWidget(panel(Store()));
    await t.pump();
    expect(find.text(witSensorMac), findsOneWidget);
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '센서 연결'))
            .onPressed,
        isNotNull);
    await t.pumpWidget(const SizedBox());
  });
}
