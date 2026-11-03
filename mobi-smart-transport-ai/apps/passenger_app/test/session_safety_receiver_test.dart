import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/session_safety_receiver.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

class Sink implements SpeechEngine {
  final played = <String>[];
  int stops = 0;
  Completer<void>? done;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) {
    played.add(text);
    done = Completer<void>();
    return done!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (done?.isCompleted == false) done!.complete();
  }
}

Map<String, dynamic> response(int cursor,
        {List<Map<String, dynamic>> events = const [],
        String generation = 'g',
        String owner = 'owner'}) =>
    {
      'sessionId': 'session',
      'ownerUid': owner,
      'generation': generation,
      'cursor': cursor,
      'events': events
    };
Map<String, dynamic> event(int seq) => {
      'sequence': seq,
      'eventId': 'e$seq',
      'priority': 'info',
      'synthetic': true,
      'message': '검증용 합성 안내 $seq',
      'validForSeconds': 3.0
    };
void main() {
  for (final attack in [
    'normal',
    'duplicate',
    'priority',
    'logout',
    'same-uid',
    'stale',
    'reconnect',
    'reconnect-generation',
    'reorder',
    'scope',
    'generation',
    'synthetic-off',
    'late-response'
  ]) {
    testWidgets('session delivery $attack', (t) async {
      final sink = Sink();
      final priority = SpeechPriorityCoordinator(sink);
      final auth = StreamController<Object?>.broadcast(sync: true);
      var current = true;
      var data = response(0);
      Completer<Map<String, dynamic>>? pending;
      final receiver = SessionSafetyReceiver(
          sessionId: 'session',
          ownerUid: 'owner',
          isCurrent: () => current,
          priority: priority,
          allowSynthetic: attack != 'synthetic-off',
          authChanges: auth.stream,
          fetch: (s, c, g) async =>
              pending == null ? data : await pending.future);
      await t.pump();
      receiver.setEnabled(true);
      if (attack == 'late-response') {
        pending = Completer();
        final polling = receiver.poll();
        current = false;
        auth.add(null);
        pending.complete(response(1, events: [event(1)]));
        await polling;
        await t.pump();
        expect(sink.played, isEmpty);
      } else {
        data = response(1, events: [event(1)]);
        if (attack == 'stale') {
          data['events'] = [
            {...event(1), 'validForSeconds': 0}
          ];
        }
        if (attack == 'scope') data['ownerUid'] = 'other';
        if (attack == 'generation') data['generation'] = 'new-generation';
        await receiver.poll();
        await t.pump();
        if (['stale', 'scope', 'generation', 'synthetic-off']
            .contains(attack)) {
          expect(sink.played, isEmpty);
        } else {
          expect(sink.played.length, 1);
          if (attack == 'normal') {
            await t.pump(const Duration(seconds: 4));
            expect(receiver.message, isNull);
          }
          if (attack == 'duplicate') {
            data = response(1);
            await receiver.poll();
            await t.pump();
            expect(sink.played.length, 1);
          }
          if (attack == 'priority') {
            final lease = priority.claimPriority();
            await t.pump();
            expect(receiver.message, isNull);
            expect(sink.stops, greaterThan(0));
            lease.release();
            data = response(1);
            await receiver.poll();
            await t.pump();
            expect(sink.played.length, 1);
          }
          if (attack == 'logout' || attack == 'same-uid') {
            current = false;
            auth.add(attack == 'same-uid' ? 'owner' : null);
            await t.pump();
            expect(receiver.message, isNull);
            expect(sink.stops, greaterThan(0));
            data = response(2, events: [event(2)]);
            await receiver.poll();
            expect(sink.played.length, 1);
          }
          if (attack == 'reconnect' || attack == 'reconnect-generation') {
            data = {};
            await receiver.poll();
            await t.pump();
            data = response(2,
                events: [event(2)],
                generation:
                    attack == 'reconnect-generation' ? 'new-generation' : 'g');
            await t.pump(const Duration(seconds: 2));
            await receiver.poll();
            await t.pump();
            if (attack == 'reconnect-generation') {
              expect(receiver.active, false);
            }
            expect(sink.played.length, 1);
          }
          if (attack == 'reorder') {
            data = response(0, events: [event(1)]);
            await receiver.poll();
            await t.pump();
            expect(sink.played.length, 1);
          }
        }
      }
      receiver.dispose();
      await t.pump();
      priority.dispose();
      await auth.close();
    });
  }
}
