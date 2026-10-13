import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/widgets/vision_observation_panel.dart';

void main() {
  Map<String, dynamic> value(String state, {double ttl = 3}) => {
        'sessionId': 's',
        'observations': [
          {
            'state': state,
            'validForSeconds': ttl,
            'sourceType': 'replay',
            'observedClasses': ['bus'],
            'receivedAt': 'test',
          }
        ]
      };
  testWidgets(
      'replay observation is display only and duplicate polling replaces content',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's', fetch: (_) async => value('available'))));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsOneWidget);
    expect(find.text('녹화 영상 기반 시연 정보입니다'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('expired data is not presented as a current bus', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's', fetch: (_) async => value('available', ttl: 0))));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsNothing);
    expect(find.text('현재 관찰 정보가 없습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('lost and query failure clear current observations',
      (tester) async {
    var fail = false;
    await tester.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's',
            fetch: (_) async {
              if (fail) throw Exception('unauthorized');
              return value('lost');
            })));
    await tester.pump();
    expect(find.text('카메라 연결이 중단되었습니다'), findsOneWidget);
    fail = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('카메라 연결이 중단되었습니다'), findsNothing);
    expect(find.text('현재 관찰 정보가 없습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('account change drops a late response from the previous user',
      (tester) async {
    final changes = StreamController<String?>();
    final pending = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's',
            ownerUid: 'alice',
            authChanges: changes.stream,
            fetch: (_) => pending.future)));
    changes.add('bob');
    await tester.pump();
    pending.complete(value('available'));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsNothing);
    expect(find.text('현재 관찰 정보가 없습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    unawaited(changes.close());
    await tester.pump();
  });
}
