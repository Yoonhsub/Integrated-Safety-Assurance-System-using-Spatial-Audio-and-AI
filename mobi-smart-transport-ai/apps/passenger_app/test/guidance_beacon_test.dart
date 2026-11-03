import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'package:mobi_passenger_app/src/widgets/guidance_beacon_panel.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'session_safety_receiver_test.dart' as audio;

class _Scanner implements BeaconScanner {
  _Scanner(this.now);
  final DateTime Function() now;
  final signals = StreamController<BeaconSignal>.broadcast(sync: true);
  bool active = false;
  int stopped = 0;
  @override
  bool get isScanning => active;
  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) {
    active = true;
    return signals.stream;
  }

  @override
  Future<void> stop() async {
    active = false;
    stopped++;
  }

  void emit(String id) => signals.add(BeaconSignal(
      beaconId: id,
      rssi: -60,
      estimatedDistanceMeters: null,
      signalLevel: BeaconSignalLevel.close,
      lastDetectedAt: now()));
}

void main() {
  Future<void> flush(WidgetTester t) async {
    for (var i = 0; i < 15; i++) {
      await t.pump();
    }
  }

  for (final mock in [false, true]) {
    testWidgets(
        'Guidance BLE ${mock ? 'explicit mock identity' : 'real unregistered'} state audio and cleanup',
        (t) async {
      var now = DateTime.utc(2026, 11, 3);
      final scanner = _Scanner(() => now),
          sink = audio.Sink(),
          auth = StreamController<Object?>.broadcast(sync: true);
      final priority = SpeechPriorityCoordinator(sink);
      var target = 'BUS_502', current = true, audioCurrent = true;
      Widget page() => MaterialApp(
          home: Scaffold(
              body: GuidanceBeaconPanel(
                  sessionId: 's',
                  scopeVersion: 1,
                  ownerUid: 'owner',
                  targetBusId: target,
                  routeNo: '502',
                  priority: priority,
                  scanner: scanner,
                  clock: () => now,
                  mockInput: mock,
                  identities: const [
                    BeaconIngestIdentity(
                        beaconId: 'AA:BB:CC:DD:EE:FF',
                        busId: 'BUS_502',
                        routeNo: '502')
                  ],
                  captureGuard: () => () => current,
                  captureAudioGuard: () => () => audioCurrent,
                  authChanges: auth.stream)));
      await t.pumpWidget(page());
      await t.tap(find.text('BLE 스캔 시작'));
      await flush(t);
      scanner.emit('OTHER');
      await flush(t);
      expect(sink.played, isEmpty);
      scanner.emit('AA:BB:CC:DD:EE:FF');
      await flush(t);
      if (mock) {
        expect(find.text('테스트 입력 · 목표 버스 비콘 일치'), findsOneWidget);
        expect(sink.played.length, 1);
        expect(sink.played.single, startsWith('테스트 입력입니다.'));
        scanner.emit('AA:BB:CC:DD:EE:FF');
        await flush(t);
        expect(sink.played.length, 1);
        // Same coordinator as general Guidance STOP / Live Hold.
        final hold = priority.claimPriority();
        audioCurrent = false;
        await flush(t);
        expect(sink.stops, greaterThan(0));
        hold.release();
        await flush(t);
        expect(sink.played.length, 1);
        now = now.add(const Duration(seconds: 6));
        await t.pump(const Duration(seconds: 6));
        await flush(t);
        expect(find.textContaining('신호 소실'), findsOneWidget);
      } else {
        expect(find.textContaining('매핑 미등록 · 목표 버스 미확인'), findsOneWidget);
        expect(sink.played, isEmpty); // A fake mapping cannot bless REAL_BLE.
      }
      target = 'BUS_OTHER';
      await t.pumpWidget(page());
      await flush(t);
      expect(scanner.active, isFalse);
      expect(find.textContaining('목표 또는 세션 변경'), findsOneWidget);
      await t.tap(find.text('BLE 스캔 시작'));
      await flush(t);
      scanner.emit('AA:BB:CC:DD:EE:FF');
      await flush(t);
      expect(sink.played.length, mock ? 1 : 0);
      current = false;
      auth.add(null);
      await flush(t);
      expect(scanner.active, isFalse);
      await t.pumpWidget(const SizedBox());
      await flush(t);
      scanner.emit('AA:BB:CC:DD:EE:FF');
      await flush(t);
      expect(sink.played.length, mock ? 1 : 0);
      priority.dispose();
      await scanner.signals.close();
      await auth.close();
      expect(t.takeException(), isNull);
    });
  }
}
