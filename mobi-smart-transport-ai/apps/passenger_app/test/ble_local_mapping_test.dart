import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'package:mobi_passenger_app/src/services/local_demo_beacon_mapping.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/widgets/guidance_beacon_panel.dart';
import '../../../packages/mobile_sensors/test/beacon_freshness_test.dart'
    as parser;
import 'session_safety_receiver_test.dart' as audio;

// These addresses are test fixtures, not measured devices or vehicle records.
Map<String, dynamic> data() => {
      'schemaVersion': 1,
      'identifierField': 'android.remoteId',
      'entries': [
        {
          'beaconId': 'AA:BB:CC:DD:EE:01',
          'busId': 'fixture-bus-502',
          'routeNo': '502'
        },
        {
          'beaconId': 'AA:BB:CC:DD:EE:02',
          'busId': 'fixture-bus-100',
          'routeNo': '100'
        }
      ]
    };
StreamController<List<T>> controllerFor<T>(T sample) =>
    StreamController<List<T>>.broadcast(sync: true);
void main() {
  test(
      'explicit local mapping validates addresses and never acts as release vehicle registry',
      () {
    expect(LocalDemoBeaconMapping.fromEnvironment().enabled, isFalse);
    expect(LocalDemoBeaconMapping.parse('', allowed: true).enabled, isFalse);
    expect(
        LocalDemoBeaconMapping.parse(jsonEncode(data()), allowed: false)
            .enabled,
        isFalse);
    final mapping =
        LocalDemoBeaconMapping.parse(jsonEncode(data()), allowed: true);
    expect(mapping.find('aa-bb-cc-dd-ee-01').single.busId, 'fixture-bus-502');
    expect(mapping.find('SHARED_NAME'), isEmpty);
    for (final bad in [
      {...data(), 'identifierField': 'advertisingName'},
      {
        ...data(),
        'entries': [
          ...(data()['entries'] as List),
          (data()['entries'] as List).first
        ]
      },
      {
        ...data(),
        'entries': [
          {'beaconId': '', 'busId': '', 'routeNo': ''}
        ]
      }
    ]) {
      expect(LocalDemoBeaconMapping.parse(jsonEncode(bad), allowed: true).issue,
          isNotNull);
    }
  });
  testWidgets(
      'real ScanResult parser fixture to local demo mapping Guidance and existing audio',
      (t) async {
    var now = DateTime.utc(2026, 11, 3), current = true;
    final raw = controllerFor(parser.observation('AA:BB:CC:DD:EE:01', now));
    var starts = 0, stops = 0;
    final scanner = FlutterBlueBeaconScanner(
        scanResults: raw.stream,
        now: () => now,
        startScan: () async {
          starts++;
        },
        stopScan: () async {
          stops++;
        });
    final sink = audio.Sink();
    final arbiter = SpeechPriorityCoordinator(sink);
    final auth = StreamController<Object?>.broadcast(sync: true);
    final mapping =
        LocalDemoBeaconMapping.parse(jsonEncode(data()), allowed: true);
    var bus = 'fixture-bus-502', route = '502';
    Widget page() => MaterialApp(
        home: Scaffold(
            body: GuidanceBeaconPanel(
                sessionId: 's',
                scopeVersion: 1,
                ownerUid: 'owner',
                targetBusId: bus,
                routeNo: route,
                priority: arbiter,
                captureGuard: () => () => current,
                captureAudioGuard: () => () => current,
                authChanges: auth.stream,
                scanner: scanner,
                demoMapping: mapping,
                clock: () => now)));
    Future<void> flush() async {
      // Native subscription cancellation may complete outside FakeAsync.
      await t.runAsync(() async {});
      for (var i = 0; i < 25; i++) {
        await t.pump(Duration.zero);
      }
    }

    await t.pumpWidget(page());
    await t.tap(find.text('BLE 스캔 시작'));
    await flush();
    raw.add([parser.observation('AA:BB:CC:DD:EE:03', now)]);
    await flush();
    expect(find.textContaining('미등록 비콘 수신'), findsOneWidget);
    expect(sink.played, isEmpty);
    raw.add([parser.observation('AA:BB:CC:DD:EE:02', now)]);
    await flush();
    expect(find.text('시연 매핑 · 다른 버스 비콘 수신'), findsOneWidget);
    expect(sink.played, isEmpty);
    raw.add([parser.observation('AA:BB:CC:DD:EE:01', now)]);
    await flush();
    expect(find.textContaining('로컬 시연 매핑 · 목표 버스 비콘 일치'), findsOneWidget);
    expect(sink.played.length, 1);
    expect(sink.played.single, startsWith('로컬 시연 매핑 기준입니다.'));
    now = now.add(const Duration(seconds: 1));
    raw.add([parser.observation('AA:BB:CC:DD:EE:01', now)]);
    await flush();
    expect(sink.played.length, 1);
    final hold = arbiter.claimPriority();
    await flush();
    expect(sink.stops, greaterThan(0));
    hold.release();
    await flush();
    expect(sink.played.length, 1);
    now = now.add(const Duration(seconds: 6));
    await t.pump(const Duration(seconds: 6));
    await flush();
    expect(find.textContaining('신호 소실'), findsOneWidget);
    raw.add([parser.observation('AA:BB:CC:DD:EE:01', now)]);
    await flush();
    expect(sink.played.length, 1);
    bus = 'fixture-bus-100';
    route = '100';
    await t.pumpWidget(page());
    await flush();
    await t.pump(const Duration(milliseconds: 1));
    await flush();
    expect(scanner.isScanning, isFalse);
    await t.tap(find.text('BLE 스캔 시작'));
    await flush();
    now = now.add(const Duration(seconds: 1));
    raw.add([parser.observation('AA:BB:CC:DD:EE:02', now)]);
    await flush();
    expect(sink.played.length, 2);
    current = false;
    auth.add(null);
    await flush();
    expect(scanner.isScanning, isFalse);
    await t.pumpWidget(const SizedBox());
    await flush();
    expect(starts, 2);
    expect(stops, 2);
    expect(t.takeException(), isNull);
    arbiter.dispose();
    await raw.close();
    await auth.close();
  });
}
