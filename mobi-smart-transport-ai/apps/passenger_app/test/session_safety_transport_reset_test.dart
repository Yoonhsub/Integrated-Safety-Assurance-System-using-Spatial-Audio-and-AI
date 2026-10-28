import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/services/session_safety_receiver.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/widgets/session_safety_panel.dart';

Map<String, dynamic> packet(int cursor,
        {List<Map<String, dynamic>> events = const [],
        String generation = 'g'}) =>
    {
      'sessionId': 'session',
      'ownerUid': 'owner',
      'generation': generation,
      'cursor': cursor,
      'events': events
    };
Map<String, dynamic> info(int sequence) => {
      'sequence': sequence,
      'eventId': 'e$sequence',
      'priority': 'info',
      'synthetic': true,
      'message': '검증용 $sequence',
      'validForSeconds': 3.0
    };

class Sink implements SpeechEngine {
  final played = <String>[];
  int stops = 0;
  Completer<void>? done;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) {
    played.add(text);
    done = Completer();
    return done!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (done?.isCompleted == false) done!.complete();
  }
}

class CountingTransport extends http.BaseClient {
  CountingTransport({this.cancellable = true});
  final bool cancellable;
  int sends = 0, active = 0, maximum = 0, aborts = 0;
  int? status;
  Map<String, dynamic> data = packet(0);
  final pending = <Completer<http.StreamedResponse>>[];
  final requests = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    active++;
    if (active > maximum) maximum = active;
    requests.add(request);
    final response = Completer<http.StreamedResponse>();
    pending.add(response);
    if (cancellable && request is http.Abortable) {
      request.abortTrigger?.then((_) {
        if (!response.isCompleted) {
          aborts++;
          response.completeError(http.RequestAbortedException(request.url));
        }
      });
    }
    if (status != null) {
      response.complete(http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(data))), status!));
    }
    try {
      return await response.future;
    } finally {
      active--;
    }
  }

  void complete(int code) {
    for (final p in pending) {
      if (!p.isCompleted) {
        p.complete(http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(data))), code));
      }
    }
  }
}

V3AgentApiClient api(CountingTransport t, String name,
        {void Function()? refresh, void Function()? logout}) =>
    V3AgentApiClient(
        baseUrl: 'http://$name.test',
        authClient: AuthenticatedApiClient(
            client: t,
            tokenLoader: ({bool forceRefresh = false}) async {
              if (forceRefresh) refresh?.call();
              return 'offline-only.owner';
            },
            onUnauthorized: () async {
              logout?.call();
            }));

void main() {
  for (final duringRefresh in [false, true]) {
    testWidgets('abort during token wait; refresh=$duringRefresh', (t) async {
      final transport = CountingTransport()..status = 401;
      final waiting = Completer<String?>();
      final abort = Completer<void>();
      var logout = 0;
      final client = AuthenticatedApiClient(
          client: transport,
          tokenLoader: ({bool forceRefresh = false}) async {
            if (duringRefresh && !forceRefresh) return 'offline-old';
            return waiting.future;
          },
          onUnauthorized: () async {
            logout++;
          });
      final result = client.get(
          Uri.parse('http://token-wait.test/guidance/safety-events'),
          abortTrigger: abort.future);
      final checked =
          expectLater(result, throwsA(isA<http.RequestAbortedException>()));
      await t.pump();
      abort.complete();
      waiting.complete('offline-new');
      await t.pump();
      await checked;
      expect(transport.sends, duringRefresh ? 1 : 0);
      expect(logout, 0);
    });
  }

  for (final cancellable in [true, false]) {
    testWidgets('12s active transport bound; cancellable=$cancellable',
        (t) async {
      final transport = CountingTransport(cancellable: cancellable);
      final client = api(transport, 'bound-$cancellable');
      final sink = Sink();
      final gate = SpeechPriorityCoordinator(sink);
      final channel = client.openSafetyPolling();
      final receiver = SessionSafetyReceiver(
          sessionId: 'session',
          ownerUid: 'owner',
          isCurrent: () => true,
          priority: gate,
          fetch: channel.fetch,
          cancelFetch: channel.close);
      await t.pump();
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(transport.maximum, 1);
      if (cancellable) {
        expect(transport.aborts, greaterThan(0));
        expect(transport.sends, lessThanOrEqualTo(3));
      } else {
        expect(transport.sends, 1);
        expect(receiver.status, contains('BLOCKED'));
      }
      receiver.dispose();
      await t.pump();
      final sent = transport.sends;
      await t.pump(const Duration(seconds: 35));
      expect(transport.sends, sent);
      transport.complete(200);
      await t.pump();
      expect(transport.active, 0);
      gate.dispose();
    });
  }
  testWidgets(
      'non-cancelling original cannot be bypassed by a new client/receiver',
      (t) async {
    final a = CountingTransport(cancellable: false),
        b = CountingTransport(cancellable: false);
    final gate = SpeechPriorityCoordinator(Sink());
    final ca = api(a, 'shared').openSafetyPolling();
    final ra = SessionSafetyReceiver(
        sessionId: 'session',
        ownerUid: 'owner',
        isCurrent: () => true,
        priority: gate,
        fetch: ca.fetch,
        cancelFetch: ca.close);
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    ra.dispose();
    final cb = api(b, 'shared').openSafetyPolling();
    final rb = SessionSafetyReceiver(
        sessionId: 'session',
        ownerUid: 'owner',
        isCurrent: () => true,
        priority: gate,
        fetch: cb.fetch,
        cancelFetch: cb.close);
    await t.pump();
    await t.pump(const Duration(seconds: 12));
    expect(a.active, 1);
    expect(b.sends, 0);
    a.complete(200);
    await t.pump();
    b.status = 200;
    await t.pump(const Duration(seconds: 30));
    await rb.poll();
    await t.pump();
    expect(b.sends, greaterThan(0));
    expect(b.maximum, 1);
    rb.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets('late401 after timeout does not refresh or sign out a new epoch',
      (t) async {
    var refresh = 0, logout = 0;
    final transport = CountingTransport(cancellable: false);
    final client = api(transport, 'late401',
        refresh: () => refresh++, logout: () => logout++);
    final gate = SpeechPriorityCoordinator(Sink());
    final ch = client.openSafetyPolling();
    final receiver = SessionSafetyReceiver(
        sessionId: 'session',
        ownerUid: 'owner',
        isCurrent: () => true,
        priority: gate,
        fetch: ch.fetch,
        cancelFetch: ch.close);
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    receiver.dispose();
    transport.complete(401);
    await t.pump();
    expect(refresh, 0);
    expect(logout, 0);
    gate.dispose();
  });
  for (final code in [401, 403, 500]) {
    testWidgets('HTTP$code auth policy and bounded recovery', (t) async {
      final transport = CountingTransport()..status = code;
      final gate = SpeechPriorityCoordinator(Sink());
      final ch = api(transport, 'status$code').openSafetyPolling();
      final receiver = SessionSafetyReceiver(
          sessionId: 'session',
          ownerUid: 'owner',
          isCurrent: () => true,
          priority: gate,
          fetch: ch.fetch,
          cancelFetch: ch.close);
      await t.pump();
      final first = transport.sends;
      if (code == 500) {
        await t.pump(const Duration(seconds: 1));
        expect(transport.sends, first);
        await t.pump(const Duration(seconds: 1));
        expect(transport.sends, first + 1);
        transport.status = 200;
        transport.data = packet(5, events: [info(5)]);
        await t.pump(const Duration(seconds: 4));
        expect(receiver.active, true);
        expect(receiver.message, isNull);
      } else {
        expect(receiver.active, false);
        await t.pump(const Duration(seconds: 30));
        expect(transport.sends, first);
      }
      receiver.dispose();
      await t.pump();
      gate.dispose();
    });
  }
  for (final scenario in [
    'success',
    'failure-retry',
    'logout',
    'same-uid',
    'dispose',
    'duplicate'
  ]) {
    testWidgets('actual reset Host lifecycle $scenario', (t) async {
      final trace = <String>[];
      final lifecycle = SessionSafetyLifecycle(trace: trace.add);
      final sink = Sink();
      final gate = SpeechPriorityCoordinator(sink);
      final auth = StreamController<Object?>.broadcast(sync: true);
      var current = true, epoch = 0, calls = 0, requests = 0;
      var generation = 'old';
      var cursor = 0;
      List<Map<String, dynamic>> events = [];
      Completer<Map<String, dynamic>>? late;
      Future<Map<String, dynamic>> fetch(String s, int? c, String? g) async {
        calls++;
        if (late != null) return late.future;
        return packet(cursor, events: events, generation: generation);
      }

      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SessionSafetyHost(
                  lifecycle: lifecycle,
                  sessionId: 'session',
                  ownerUid: 'owner',
                  captureGuard: () {
                    final captured = epoch;
                    return () => current && epoch == captured;
                  },
                  authChanges: auth.stream,
                  priority: gate,
                  fetch: fetch,
                  allowSynthetic: true))));
      await t.pump();
      await t.tap(find.byType(Switch));
      await t.pump();
      // A pre-reset HTTP result remains unresolved across the reset boundary.
      late = Completer();
      await t.pump(const Duration(seconds: 1));
      final old = late;
      late = null;
      final barrier = Completer<void>();
      final captured = epoch;
      final resetting = lifecycle.reset(
          isCurrent: () => current && epoch == captured,
          request: () async {
            requests++;
            await barrier.future;
            generation = 'new';
            cursor = 0;
            events = [];
          });
      await t.pump();
      expect(find.textContaining('RESETTING'), findsOneWidget);
      final before = calls;
      await t.pump(const Duration(seconds: 2));
      expect(calls, before);
      expect(trace.where((x) => x == 'new_receiver_bound').length, 1);
      old.complete(packet(1, events: [info(1)]));
      await t.pump();
      expect(sink.played, isEmpty);
      if (scenario == 'duplicate') {
        expect(
            await lifecycle.reset(
                isCurrent: () => true,
                request: () async {
                  requests++;
                }),
            false);
      }
      if (scenario == 'logout') {
        current = false;
        auth.add(null);
      }
      if (scenario == 'same-uid') {
        epoch++;
        auth.add('owner');
      }
      if (scenario == 'dispose') {
        await t.pumpWidget(const SizedBox());
        lifecycle.dispose();
      }
      if (scenario == 'failure-retry') {
        final failed = expectLater(resetting, throwsStateError);
        barrier.completeError(StateError('offline reset failure'));
        await failed;
        await t.pump();
        expect(lifecycle.active, false);
        expect(trace.where((x) => x == 'new_receiver_bound').length, 1);
        await lifecycle.reset(
            isCurrent: () => true,
            request: () async {
              generation = 'new';
              cursor = 0;
              events = [];
            });
      } else {
        barrier.complete();
        await resetting;
      }
      await t.pump();
      await t.pump(); // Mount receiver, then render its initial async baseline.
      if (['logout', 'same-uid', 'dispose'].contains(scenario)) {
        expect(trace.where((x) => x == 'new_receiver_bound').length, 1);
      } else {
        expect(lifecycle.active, true);
        expect(find.text('안전 이벤트 연결됨'), findsOneWidget);
        await t.tap(find.byType(Switch));
        await t.pump();
        cursor = 2;
        events = [info(2)];
        await t.pump(const Duration(seconds: 1));
        expect(sink.played, ['검증용 2']);
        final start = trace.indexOf('old_receiver_invalidated');
        expect(
            trace.sublist(start),
            containsAllInOrder([
              'old_receiver_invalidated',
              'reset_request',
              'server_reset_success',
              'new_receiver_bound',
              'polling_resumed'
            ]));
      }
      if (scenario == 'duplicate') expect(requests, 1);
      debugPrint('RESET_TRACE $scenario: ${trace.join(' -> ')}');
      await t.pumpWidget(const SizedBox());
      await t.pump();
      if (scenario != 'dispose') lifecycle.dispose();
      await t.pump();
      gate.dispose();
      await auth.close();
    });
  }
}
