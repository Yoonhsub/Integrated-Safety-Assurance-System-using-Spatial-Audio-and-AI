import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/concurrent_test_control.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/concurrent_hardware_test_page.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

class Scanner implements BeaconScanner {
  final stream = StreamController<BeaconSignal>();
  int starts = 0, stops = 0;
  bool failStart = false;
  String? target;
  @override
  bool get isScanning => starts > stops;
  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) {
    starts++;
    if (failStart) throw StateError('scan start failed');
    target = targetBeaconId;
    return stream.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

class Tts implements SpeechEngine {
  final said = <String>[];
  Completer<void>? pending;
  bool failStop = false;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) async {
    said.add(text);
    await pending?.future;
  }

  @override
  Future<void> stop() async {
    if (failStop) throw StateError("audio stop failed");
  }
}

class Output implements SpatialTestOutput {
  @override
  Future<void> prepareFromGesture() async {}
  @override
  Future<bool> play(String mode, String direction) async => true;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Map<String, dynamic> snapshot() => {};
}

class RetainedPanel extends StatefulWidget {
  const RetainedPanel(this.name, {super.key});
  final String name;
  @override
  State<RetainedPanel> createState() => RetainedState();
}

class RetainedState extends State<RetainedPanel> {
  bool running = false;
  @override
  Widget build(BuildContext context) => TextButton(
      onPressed: () => setState(() => running = !running),
      child: Text('${widget.name}:$running'));
}

BeaconSignal signal(String mac, {DateTime? at, int rssi = -50}) => BeaconSignal(
    beaconId: mac,
    rssi: rssi,
    estimatedDistanceMeters: 0,
    signalLevel: BeaconSignalLevel.close,
    lastDetectedAt: at ?? DateTime.now());
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const mac = 'AA:BB:CC:DD:EE:FF';
  test(
      'user pairing requires valid number and exact normalized MAC plus freshness',
      () {
    expect(TemporaryBusTarget.parse('502', 'name'), isNull);
    final target = TemporaryBusTarget.parse('502', 'aa-bb-cc-dd-ee-ff')!;
    final now = DateTime.now();
    expect(target.matches(signal(mac, at: now), now), isTrue);
    expect(target.matches(signal('AA:BB:CC:DD:EE:00', at: now), now), isFalse);
    expect(
        target.matches(
            signal(mac, at: now.subtract(const Duration(seconds: 3))), now),
        isFalse);
    expect(
        target.matches(
            signal(mac, at: now.add(const Duration(seconds: 1))), now),
        isFalse);
    expect(target.matches(signal(mac, at: now, rssi: -121), now), isFalse);
    expect(target.announcement, contains('502번 버스가 진입 중입니다'));
    expect(target.announcement, contains('실제 버스 접근을 확인한 것은 아닙니다'));
  });
  test('busy output drops without preempting or queuing old observation',
      () async {
    final gate = ConcurrentObservationGate(), done = Completer<bool>();
    var plays = 0;
    final first = gate.run(() {
      plays++;
      return done.future;
    });
    expect(
        await gate.run(() async {
          plays++;
          return true;
        }),
        isFalse);
    expect(plays, 1);
    done.complete(true);
    expect(await first, isTrue);
    expect(await gate.run(() async => true), isTrue);
  });
  testWidgets(
      'scan, WT and camera controls remain independently mounted; strict bus speech',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final scanner = Scanner(), tts = Tts();
    final engine = SpatialVerificationEngine(Output(), tts);
    await t.pumpWidget(MaterialApp(
        home: ConcurrentHardwareTestPage(
            engine: engine,
            scannerFactory: (_) => scanner,
            ensurePermission: () async => true,
            sensorBuilder: (_) => const RetainedPanel('WT'),
            cameraBuilder: (_, __, ___, ____) =>
                const RetainedPanel('camera'))));
    await t.pumpAndSettle();
    await t.tap(find.text('번호·MAC 설정'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '시연 버스 번호'), '502');
    await t.enterText(
        find.widgetWithText(
            TextField, '실제 Android 비콘 MAC (예: AA:BB:CC:DD:EE:FF)'),
        mac);
    await t.tap(find.text('완료'));
    await t.pumpAndSettle();
    Future<void> tap(String text) async {
      if (text.startsWith('camera:')) {
        await t.tap(find.textContaining('2 카메라'));
        await t.pump();
      } else {
        await t.tap(find.textContaining('1 버스·WT'));
        await t.pump();
      }
      await t.ensureVisible(find.text(text));
      await t.tap(find.text(text));
      await t.pump();
    }

    await tap('WT:false');
    await tap('camera:false');
    final wt = t.state<RetainedState>(find.byWidgetPredicate(
        (w) => w is RetainedPanel && w.name == 'WT',
        skipOffstage: false));
    final camera = t.state<RetainedState>(find.byWidgetPredicate(
        (w) => w is RetainedPanel && w.name == 'camera',
        skipOffstage: false));
    await tap('버스 탐색 시작');
    await t.pump();
    expect(scanner.target, mac);
    await t.ensureVisible(find.byType(SwitchListTile));
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    scanner.stream.add(signal('AA:BB:CC:DD:EE:00'));
    await t.pump();
    expect(tts.said, isEmpty);
    final observed = signal(mac);
    scanner.stream.add(observed);
    await t.pump();
    await t.pump();
    expect(tts.said, hasLength(1));
    expect(tts.said.single, contains('502번 버스가 진입 중입니다'));
    scanner.stream.add(observed);
    scanner.stream.add(signal(mac));
    await t.pump();
    expect(tts.said, hasLength(1));
    expect(wt.running, isTrue);
    expect(camera.running, isTrue);
    await tap('버스 탐색 중지');
    await t.pump();
    expect(scanner.stops, 1);
    expect(wt.running, isTrue);
    expect(camera.running, isTrue);
    await tap('camera:true');
    expect(wt.running, isTrue);
    expect(camera.running, isFalse);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    unawaited(scanner.stream.close());
  });
  testWidgets('pending permission completion cannot restart scan after stop',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final scanner = Scanner(), permission = Completer<bool>();
    await t.pumpWidget(MaterialApp(
        home: ConcurrentHardwareTestPage(
            engine: SpatialVerificationEngine(Output(), Tts()),
            scannerFactory: (_) => scanner,
            ensurePermission: () => permission.future,
            sensorBuilder: (_) => const SizedBox(),
            cameraBuilder: (_, __, ___, ____) => const SizedBox())));
    await t.pumpAndSettle();
    await t.tap(find.text('번호·MAC 설정'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '시연 버스 번호'), '502');
    await t.enterText(
        find.widgetWithText(
            TextField, '실제 Android 비콘 MAC (예: AA:BB:CC:DD:EE:FF)'),
        mac);
    await t.tap(find.text('완료'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('버스 탐색 시작'));
    await t.tap(find.text('버스 탐색 시작'));
    await t.pump();
    await t.tap(find.text('버스 탐색 중지'));
    await t.pump();
    permission.complete(true);
    await t.pump();
    await t.pump();
    expect(scanner.starts, 0);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    unawaited(scanner.stream.close());
  });
  testWidgets('scanner synchronous start failure cleans up and enables retry',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final scanner = Scanner()..failStart = true;
    await t.pumpWidget(MaterialApp(
        home: ConcurrentHardwareTestPage(
            engine: SpatialVerificationEngine(Output(), Tts()),
            scannerFactory: (_) => scanner,
            ensurePermission: () async => true,
            sensorBuilder: (_) => const SizedBox(),
            cameraBuilder: (_, __, ___, ____) => const SizedBox())));
    await t.pumpAndSettle();
    await t.tap(find.text('번호·MAC 설정'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '시연 버스 번호'), '502');
    await t.enterText(
        find.widgetWithText(
            TextField, '실제 Android 비콘 MAC (예: AA:BB:CC:DD:EE:FF)'),
        mac);
    await t.tap(find.text('완료'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('버스 탐색 시작'));
    await t.tap(find.text('버스 탐색 시작'));
    for (var i = 0; i < 8; i++) {
      await t.pump();
    }
    expect(scanner.stops, 1);
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '버스 탐색 시작'))
            .onPressed,
        isNotNull);
    scanner.failStart = false;
    await t.tap(find.text('버스 탐색 시작'));
    await t.pump();
    await t.pump();
    expect(scanner.starts, 2);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    unawaited(scanner.stream.close());
  });
  testWidgets('audio stop failure cannot prevent BLE scanner cleanup',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final scanner = Scanner();
    final tts = Tts()..pending = Completer<void>();
    await t.pumpWidget(MaterialApp(
        home: ConcurrentHardwareTestPage(
            engine: SpatialVerificationEngine(Output(), tts),
            scannerFactory: (_) => scanner,
            ensurePermission: () async => true,
            sensorBuilder: (_) => const SizedBox(),
            cameraBuilder: (_, __, ___, ____) => const SizedBox())));
    await t.pumpAndSettle();
    await t.tap(find.text('번호·MAC 설정'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '시연 버스 번호'), '502');
    await t.enterText(
        find.widgetWithText(
            TextField, '실제 Android 비콘 MAC (예: AA:BB:CC:DD:EE:FF)'),
        mac);
    await t.tap(find.text('완료'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('버스 탐색 시작'));
    await t.tap(find.text('버스 탐색 시작'));
    await t.pump();
    await t.ensureVisible(find.byType(SwitchListTile));
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    scanner.stream.add(signal(mac));
    for (var i = 0; i < 5; i++) {
      await t.pump();
    }
    expect(tts.said, hasLength(1));
    tts.failStop = true;
    await t.ensureVisible(find.text('버스 탐색 중지'));
    await t.tap(find.text('버스 탐색 중지'));
    for (var i = 0; i < 8; i++) {
      await t.pump();
    }
    expect(scanner.stops, 1);
    expect(scanner.stream.hasListener, isFalse);
    tts.failStop = false;
    tts.pending!.complete();
    await t.pumpWidget(const SizedBox());
    await t.pump();
    unawaited(scanner.stream.close());
  });
}
