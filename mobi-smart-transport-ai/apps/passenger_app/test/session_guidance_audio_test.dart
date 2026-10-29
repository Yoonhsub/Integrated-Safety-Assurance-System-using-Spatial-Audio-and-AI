import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/session_safety_receiver.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'directional_guidance_test.dart' as d;
import 'vision_observation_tts_test.dart' as f;
import 'session_safety_receiver_test.dart' as s;

void main() {
  for (final scenario in [
    'tts-only',
    'left',
    'center',
    'right',
    'mode-off',
    'unknown-direction',
    'wrong-owner',
    'wrong-session',
    'wrong-generation',
    'wrong-epoch',
    'wrong-frame',
    'old-receipt',
    'future-receipt',
    'non-synthetic',
    'stop-before-cue-completion',
    'hold-before-tts',
    'logout',
    'same-uid-epoch',
    'reset',
    'dispose',
    'duplicate',
    'stale',
    'no-event',
    'reserved-text',
    'cue-error',
    'old-callback-new-receiver'
  ]) {
    testWidgets('actual receiver to guidance audio $scenario', (t) async {
      final output = d.CueOutput(), tts = f.FakeTts();
      final engine = SpatialVerificationEngine(output, tts);
      final priority = SpeechPriorityCoordinator(engine);
      final auth = StreamController<Object?>.broadcast(sync: true);
      var epoch = 1, current = true;
      final now = DateTime.utc(2026, 10, 28);
      final directional = ![
        'tts-only',
        'mode-off',
        'unknown-direction',
        'no-event'
      ].contains(scenario);
      final receipt = LocalDirectionReceipt(
          sessionId: scenario == 'wrong-session' ? 'other' : 'session',
          ownerUid: scenario == 'wrong-owner' ? 'other' : 'owner',
          generation: scenario == 'wrong-generation' ? 'other' : 'g',
          authEpoch: scenario == 'wrong-epoch' ? 2 : 1,
          eventId: 'e1',
          direction: scenario == 'right'
              ? TestDirection.right
              : scenario == 'center'
                  ? TestDirection.center
                  : TestDirection.left,
          coordinateFrame: scenario == 'wrong-frame'
              ? 'world'
              : 'listener-relative-rightX-upY-forwardMinusZ',
          createdAt: scenario == 'old-receipt'
              ? now.subtract(const Duration(seconds: 4))
              : scenario == 'future-receipt'
                  ? now.add(const Duration(seconds: 1))
                  : now);
      final adapter = scenario == 'mode-off'
          ? SessionGuidanceAudio(priority: priority)
          : SessionGuidanceAudio.localVerification(
              priority: priority,
              engine: engine,
              authEpoch: () => epoch,
              clock: () => now,
              receipt: (_) => directional ? receipt : null);
      var data = s.response(0);
      final receiver = SessionSafetyReceiver(
          sessionId: 'session',
          ownerUid: 'owner',
          isCurrent: () => current && epoch == 1,
          fetch: (_, __, ___) async => data,
          priority: priority,
          audio: adapter,
          authChanges: auth.stream,
          allowSynthetic: true);
      await t.pump();
      receiver.setEnabled(true);
      final event = {
        ...s.event(1),
        'testDirection': 'LEFT',
        'coordinateFrame': 'forged'
      };
      if (scenario == 'non-synthetic') event['synthetic'] = false;
      if (scenario == 'stale') event['validForSeconds'] = 0;
      if (scenario == 'reserved-text') event['message'] = '@guidance:1';
      if (scenario == 'cue-error') output.failCue = true;
      data = s.response(1, events: scenario == 'no-event' ? [] : [event]);
      await receiver.poll();
      await t.pump();
      final refused = [
        'wrong-owner',
        'wrong-session',
        'wrong-generation',
        'wrong-epoch',
        'wrong-frame',
        'old-receipt',
        'future-receipt',
        'non-synthetic',
        'stale',
        'no-event',
        'reserved-text',
        'cue-error'
      ];
      if (refused.contains(scenario)) {
        expect(tts.spoken, isEmpty);
        expect(output.commands, isEmpty);
      } else if (!directional) {
        expect(output.commands, isEmpty);
        expect(tts.spoken, hasLength(1));
      } else {
        expect(output.commands, hasLength(1));
        expect(tts.spoken, isEmpty);
        if (scenario == 'stop-before-cue-completion') {
          receiver.setEnabled(false);
        }
        if (scenario == 'hold-before-tts') {
          final lease = priority.claimPriority();
          await t.pump();
          lease.release();
        }
        if (['logout', 'same-uid-epoch', 'reset', 'old-callback-new-receiver']
            .contains(scenario)) {
          epoch++;
          auth.add('owner');
        }
        if (scenario == 'dispose') {
          receiver.close();
          priority.dispose();
        }
        await t.pump();
        output.finish();
        await t.pump();
        if (['left', 'center', 'right', 'duplicate'].contains(scenario)) {
          expect(tts.spoken, hasLength(1));
          if (scenario == 'duplicate') {
            await receiver.poll();
            await t.pump();
            expect(output.commands, hasLength(1));
          }
        } else {
          expect(tts.spoken, isEmpty);
        }
        if (scenario == 'old-callback-new-receiver') {
          final next = f.FakeTts(), gate = SpeechPriorityCoordinator(next);
          final owner = Object();
          final playing =
              gate.speakObservation(owner, 'new generation', () => true);
          await t.pump();
          output.finish();
          await t.pump();
          expect(next.spoken, ['new generation']);
          next.finish();
          await t.pump();
          await playing;
          gate.dispose();
        }
      }
      receiver.dispose();
      await t.pump();
      await engine.dispose();
      priority.dispose();
      await auth.close();
      await t.pump();
      expect(output.disposed, isTrue);
    });
  }
  test('different coordinators cannot bypass receiver arbitration', () {
    final a = SpeechPriorityCoordinator(f.FakeTts()),
        b = SpeechPriorityCoordinator(f.FakeTts());
    expect(
        () => SessionSafetyReceiver(
            sessionId: 's',
            ownerUid: 'u',
            isCurrent: () => true,
            fetch: (_, __, ___) async => {},
            priority: a,
            audio: SessionGuidanceAudio(priority: b)),
        throwsArgumentError);
    a.dispose();
    b.dispose();
  });
  for (final url in [
    'http://127.0.0.1:8280',
    'https://production.invalid',
    'http://127.0.0.1:8280?test=true',
    'http://user@localhost:8280',
    'http://localhost:8280/path',
    'http://localhost:8280#test'
  ]) {
    test('local runtime target fails closed: $url', () {
      final auth = _Auth(), priority = SpeechPriorityCoordinator(f.FakeTts());
      final client = V3AgentApiClient(
          baseUrl: url,
          authClient: AuthenticatedApiClient(
              tokenLoader: auth.getIdToken,
              requestGuard: () => () => true,
              client: MockClient((_) async => http.Response('{}', 200))));
      LocalGuidanceRuntime create() => LocalGuidanceRuntime(
          client: client,
          auth: auth,
          captureGuard: () => () => true,
          priority: priority,
          audio: SessionGuidanceAudio(priority: priority),
          controls: (_, __, ___) => const SizedBox());
      if (url == 'http://127.0.0.1:8280') {
        expect(create, returnsNormally);
      } else {
        expect(create, throwsStateError);
      }
      priority.dispose();
    });
  }
  testWidgets(
      'receiver shutdown timeout preserves quarantine and late disposal safety',
      (t) async {
    final output = d.CueOutput(), tts = f.FakeTts();
    final engine = SpatialVerificationEngine(output, tts),
        auth = StreamController<Object?>.broadcast();
    final gate = SpeechPriorityCoordinator(engine);
    final now = DateTime.utc(2026, 10, 28);
    var data = s.response(0);
    final receiver = SessionSafetyReceiver(
        sessionId: 'session',
        ownerUid: 'owner',
        isCurrent: () => true,
        fetch: (_, __, ___) async => data,
        priority: gate,
        allowSynthetic: true,
        authChanges: auth.stream,
        audio: SessionGuidanceAudio.localVerification(
            priority: gate,
            engine: engine,
            authEpoch: () => 1,
            clock: () => now,
            receipt: (id) => LocalDirectionReceipt(
                sessionId: 'session',
                ownerUid: 'owner',
                generation: 'g',
                authEpoch: 1,
                eventId: id,
                createdAt: now,
                direction: TestDirection.left)));
    await t.pump();
    receiver.setEnabled(true);
    data = s.response(1, events: [s.event(1)]);
    await receiver.poll();
    await t.pump();
    expect(output.commands, hasLength(1));
    output.stopGate = Completer<void>();
    receiver.setEnabled(false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 3100));
    expect(gate.priorityActive, isTrue);
    receiver.dispose();
    gate.dispose();
    output.stopGate!.complete();
    await t.pump();
    await engine.dispose();
    await auth.close();
    await t.pump();
    expect(tts.spoken, isEmpty);
    expect(output.disposed, isTrue);
    expect(t.takeException(), isNull);
  });
  test('resource close errors remain observable', () async {
    final output = d.CueOutput()..failClose = true;
    final engine = SpatialVerificationEngine(output, f.FakeTts());
    await expectLater(engine.dispose(), throwsStateError);
  });
}

class _Auth implements AuthSession {
  @override
  AuthAccount? get currentAccount => const AuthAccount(uid: 'owner');
  @override
  Stream<AuthAccount?> get authStateChanges => const Stream.empty();
  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async =>
      'offline-test';
  @override
  Future<Object?> getCustomClaim(String name,
          {bool forceRefresh = false}) async =>
      null;
  @override
  Future<void> signOut() async {}
  @override
  Future<AuthAccount> signIn(String email, String password) async =>
      currentAccount!;
}
