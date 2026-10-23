import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/widgets/beacon_observation_panel.dart';

Map<String, dynamic> snapshot(String sessionId, {double ttl = 5}) => {
      'sessionId': sessionId,
      'guidanceEligible': false,
      'shouldSpeak': false,
      'shouldPlaySpatialCue': false,
      'observations': [
        {
          'beaconId': 'test-beacon',
          'rssi': -60,
          'source': 'MANUAL_TEST',
          'validForSeconds': ttl,
          'guidanceEligible': false,
          'vehicleIdentityVerified': false,
        }
      ],
    };

void main() {
  testWidgets('shows a test measurement without offering an audio action', (tester) async {
    await tester.pumpWidget(MaterialApp(home: BeaconObservationPanel(
      sessionId: 's', fetch: (sid) async => snapshot(sid),
    )));
    await tester.pump();
    expect(find.textContaining('test-beacon'), findsOneWidget);
    expect(find.textContaining('테스트 입력'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejects data from a different session', (tester) async {
    await tester.pumpWidget(MaterialApp(home: BeaconObservationPanel(
      sessionId: 's', fetch: (_) async => snapshot('other'),
    )));
    await tester.pump();
    expect(find.textContaining('test-beacon'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hides expired measurements and ignores a response after disposal', (tester) async {
    var requests = 0;
    final pending = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(home: BeaconObservationPanel(
      sessionId: 's', fetch: (sid) => ++requests == 1
          ? Future.value(snapshot(sid, ttl: 0)) : pending.future,
    )));
    await tester.pump();
    expect(find.textContaining('test-beacon'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('test-beacon'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    pending.complete(snapshot('s'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('auth change clears current content and discards late requests', (tester) async {
    final auth = StreamController<String?>();
    await tester.pumpWidget(MaterialApp(home: BeaconObservationPanel(
      sessionId: 's', ownerUid: 'alice', authChanges: auth.stream,
      fetch: (sid) async => snapshot(sid),
    )));
    await tester.pump();
    expect(find.textContaining('test-beacon'), findsOneWidget);
    auth.add('bob');
    await tester.pump();
    expect(find.textContaining('test-beacon'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.close();
  });

  testWidgets('rejects unexpected guidance activation flags', (tester) async {
    await tester.pumpWidget(MaterialApp(home: BeaconObservationPanel(
      sessionId: 's', fetch: (sid) async => snapshot(sid)..['shouldSpeak'] = true,
    )));
    await tester.pump();
    expect(find.textContaining('test-beacon'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
