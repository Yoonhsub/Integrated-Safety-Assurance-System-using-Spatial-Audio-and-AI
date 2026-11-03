import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/session_safety_receiver.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'directional_guidance_test.dart' as d;
import 'vision_observation_tts_test.dart' as f;

void main() {
  for (final mode in ['directional', 'tts-only']) {
    for (final attack in [
      'complete-after-ttl',
      'expired-before-start',
      'cue-crosses-ttl',
      'stop-cue',
      'hold-tts',
      'session-end',
      'same-uid-epoch',
      'generation-change',
      'expired-replay',
      'reverse-callback',
      'watchdog',
      'watchdog-stop-timeout-late-dispose',
      'double-dispose',
      'long-sentence',
      'no-event',
      'same-message-while-playing'
    ]) {
      testWidgets('$mode admission/playback $attack', (t) async {
        final origin = t.binding.clock.now();
        int now() => t.binding.clock.now().difference(origin).inMicroseconds;
        final output = d.CueOutput(), tts = f.FakeTts();
        final engine = SpatialVerificationEngine(output, tts),
            gate = SpeechPriorityCoordinator(engine);
        final auth = StreamController<Object?>.broadcast(sync: true),
            records = <Map<String, Object?>>[];
        var epoch = 1, current = true, seq = 0, gen = 'g';
        Completer<Map<String, dynamic>>? delayed;
        final observation = <String, dynamic>{
          'sequence': 1,
          'eventId': 'e1',
          'message': 'A long information sentence.',
          'timestamp': '2026-10-29T00:00:00Z',
          'priority': 'info',
          'synthetic': true,
          'validForSeconds': 3.0
        };
        Map<String, dynamic> response(int? after) => {
              'sessionId': 's',
              'ownerUid': 'u',
              'generation': gen,
              'cursor': seq,
              'events': after != null && after < seq
                  ? [
                      {...observation, 'sequence': seq}
                    ]
                  : []
            };
        final adapter = SessionGuidanceAudio.localVerification(
            priority: gate,
            engine: engine,
            authEpoch: () => epoch,
            trace: records.add,
            clock: () => DateTime.utc(2026, 10, 29),
            receipt: (id) => mode == 'directional'
                ? LocalDirectionReceipt(
                    sessionId: 's',
                    ownerUid: 'u',
                    generation: 'g',
                    authEpoch: 1,
                    eventId: id,
                    createdAt: DateTime.utc(2026, 10, 29),
                    direction: TestDirection.left)
                : null);
        final receiver = SessionSafetyReceiver(
            sessionId: 's',
            ownerUid: 'u',
            isCurrent: () => current && epoch == 1,
            monotonicMicros: now,
            fetch: (_, after, __) async =>
                delayed == null ? response(after) : await delayed.future,
            priority: gate,
            audio: adapter,
            authChanges: auth.stream,
            allowSynthetic: true);
        await t.pump();
        receiver.setEnabled(true);
        if (attack == 'no-event') {
          await t.pump(const Duration(seconds: 4));
          expect(tts.spoken, isEmpty);
        } else {
          seq = 1;
          if (attack == 'expired-replay') {
            observation['validForSeconds'] = 0.0;
          }
          if (attack == 'expired-before-start') {
            // Request latency consumes2.5s of the unchanged3s freshness budget;
            // the pending prepare then crosses admission expiry before actual sound.
            delayed = Completer();
            final pending = receiver.poll();
            await t.pump(const Duration(milliseconds: 2500));
            if (mode == 'directional') {
              output.preparing = Completer();
            } else {
              tts.preparing = Completer();
            }
            delayed.complete(response(0));
            delayed = null;
            await pending;
            await t.pump();
            await t.pump(const Duration(seconds: 1));
            output.preparing?.complete();
            tts.preparing?.complete();
            await t.pump();
            expect(output.commands, isEmpty);
            expect(tts.spoken, isEmpty);
            expect(
                records.any(
                    (e) => e['cancelReason'] == 'EVENT_EXPIRED_BEFORE_START'),
                isTrue);
          } else {
            await receiver.poll();
            await t.pump();
            if (attack == 'expired-replay') {
              expect(output.commands, isEmpty);
              expect(tts.spoken, isEmpty);
              observation['validForSeconds'] = 3.0;
              seq = 2;
              await receiver.poll();
              await t.pump();
              expect(tts.spoken, isEmpty);
              expect(output.commands, isEmpty);
            } else {
              if (mode == 'directional') {
                expect(output.commands, hasLength(1));
                expect(tts.spoken, isEmpty);
                if (attack == 'stop-cue') receiver.setEnabled(false);
                if (attack == 'cue-crosses-ttl') {
                  await t.pump(const Duration(seconds: 4));
                }
                output.finish();
                await t.pump();
              }
              if (attack == 'stop-cue') {
                if (mode == 'tts-only') {
                  receiver.setEnabled(false);
                  await t.pump();
                }
                expect(mode == 'directional' ? tts.spoken.length : 0, 0);
              } else {
                expect(tts.spoken, hasLength(1));
                if (attack == 'hold-tts') {
                  final hold = gate.claimPriority();
                  await t.pump();
                  expect(tts.playing!.isCompleted, isTrue);
                  hold.release();
                } else if (attack == 'session-end') {
                  receiver.close();
                } else if (attack == 'same-uid-epoch') {
                  epoch++;
                  auth.add('u');
                } else if (attack == 'generation-change') {
                  gen = 'g2';
                  await receiver.poll();
                } else if (attack == 'double-dispose') {
                  receiver.close();
                  receiver.close();
                  gate.dispose();
                  gate.dispose();
                } else if (attack == 'watchdog' ||
                    attack == 'watchdog-stop-timeout-late-dispose') {
                  if (attack.endsWith('late-dispose')) {
                    output.stopGate = Completer();
                  }
                  await t.pump(const Duration(seconds: 30));
                  await t.pump();
                  if (attack.endsWith('late-dispose')) {
                    await t.pump(const Duration(milliseconds: 3100));
                    expect(gate.priorityActive, isTrue);
                    expect(
                        records.any(
                            (e) => e['cancelReason'] == 'PLAYBACK_WATCHDOG'),
                        isTrue);
                    expect(
                        records.any((e) => e['phase'] == 'AUDIO_QUARANTINED'),
                        isTrue);
                    receiver.close();
                    gate.dispose();
                    output.stopGate!.complete();
                    await t.pump();
                  } else {
                    expect(tts.playing!.isCompleted, isTrue);
                    expect(
                        records.any(
                            (e) => e['cancelReason'] == 'PLAYBACK_WATCHDOG'),
                        isTrue);
                  }
                } else {
                  // TTL expires, display expires, active playback is still owned.
                  await t.pump(const Duration(seconds: 5));
                  expect(tts.playing!.isCompleted, isFalse);
                  expect(receiver.message, isNull);
                  expect(
                      records.any((e) =>
                          e['phase'] ==
                          'EVENT_FRESHNESS_EXPIRED_PLAYBACK_CONTINUES'),
                      isTrue);
                  if (attack == 'same-message-while-playing') {
                    seq = 2;
                    observation['eventId'] = 'e2';
                    await receiver.poll();
                    await t.pump();
                    expect(tts.playing!.isCompleted, isFalse);
                    expect(tts.spoken, hasLength(1));
                  }
                  final old = tts.playing!;
                  tts.finish();
                  await t.pump();
                  if (attack == 'reverse-callback') {
                    output.finish();
                    if (!old.isCompleted) old.complete();
                    await t.pump();
                  }
                  expect(records.any((e) => e['phase'] == 'ttsCompletedAt'),
                      isTrue);
                }
                await t.pump();
                if ([
                  'session-end',
                  'same-uid-epoch',
                  'generation-change',
                  'double-dispose'
                ].contains(attack)) {
                  expect(tts.playing!.isCompleted, isTrue);
                }
              }
            }
          }
        }
        receiver.dispose();
        await t.pump();
        await engine.dispose();
        gate.dispose();
        await auth.close();
        await t.pump();
        expect(t.takeException(), isNull);
        expect(output.disposed, isTrue);
      });
    }
  }
  testWidgets('plain production speech admission is checked after prepare',
      (t) async {
    var micros = 0;
    final sink = f.FakeTts()..preparing = Completer<void>();
    final gate = SpeechPriorityCoordinator(sink),
        records = <Map<String, Object?>>[];
    final admission = ObservationAdmission(
        deadlineMicros: 3000000,
        nowMicros: () => micros,
        eventId: 'e',
        sessionGeneration: 'g',
        receivedAt: '2026-10-29',
        trace: records.add);
    final output = SessionGuidanceAudio(priority: gate);
    final result = output.speak(
        Object(),
        const SessionGuidanceObservation(
            sessionId: 's',
            ownerUid: 'u',
            generation: 'g',
            eventId: 'e',
            text: 'safe information',
            synthetic: false),
        () => true,
        admission: admission);
    await t.pump();
    micros = 3000000;
    sink.preparing!.complete();
    await t.pump();
    expect(await result, isFalse);
    expect(sink.spoken, isEmpty);
    gate.dispose();
  });
  testWidgets(
      'local producer uses only owner-verified receiver baseline generation',
      (t) async {
    var gen = 'g', owner = 'u';
    final scopes = <String>[];
    final gate = SpeechPriorityCoordinator(f.FakeTts());
    final receiver = SessionSafetyReceiver(
        sessionId: 's',
        ownerUid: 'u',
        isCurrent: () => true,
        fetch: (_, __, ___) async => {
              'sessionId': 's',
              'ownerUid': owner,
              'generation': gen,
              'cursor': 0,
              'events': []
            },
        priority: gate,
        audio: SessionGuidanceAudio(
            priority: gate, onScope: (sid, g) => scopes.add('$sid/$g')));
    await t.pump();
    expect(scopes, ['s/g']);
    gen = 'foreign-generation';
    await receiver.poll();
    await t.pump();
    expect(receiver.active, isFalse);
    expect(scopes, ['s/g']);
    receiver.dispose();
    await t.pump();
    gate.dispose();
    final otherGate = SpeechPriorityCoordinator(f.FakeTts());
    owner = 'foreign';
    final other = SessionSafetyReceiver(
        sessionId: 's',
        ownerUid: 'u',
        isCurrent: () => true,
        fetch: (_, __, ___) async => {
              'sessionId': 's',
              'ownerUid': owner,
              'generation': 'x',
              'cursor': 0,
              'events': []
            },
        priority: otherGate,
        audio: SessionGuidanceAudio(
            priority: otherGate, onScope: (sid, g) => scopes.add('$sid/$g')));
    await t.pump();
    expect(scopes, ['s/g']);
    other.dispose();
    await t.pump();
    otherGate.dispose();
  });
  for (final scenario in ['ready', 'expired', 'epoch-changed']) {
    testWidgets('test-only producer receipt barrier $scenario', (t) async {
      final origin = t.binding.clock.now();
      int now() => t.binding.clock.now().difference(origin).inMicroseconds;
      final output = d.CueOutput(), tts = f.FakeTts();
      final engine = SpatialVerificationEngine(output, tts),
          gate = SpeechPriorityCoordinator(engine);
      final pending = Completer<void>();
      LocalDirectionReceipt? receipt;
      var epoch = 1;
      final adapter = SessionGuidanceAudio.localVerification(
          priority: gate,
          engine: engine,
          authEpoch: () => epoch,
          clock: () => DateTime.utc(2026, 10, 29),
          waitForLocalBinding: () => pending.future,
          receipt: (_) => receipt);
      final admission = ObservationAdmission(
          deadlineMicros: 3000000,
          nowMicros: now,
          eventId: 'e',
          sessionGeneration: 'g',
          receivedAt: '2026-10-29');
      final result = adapter.speak(
          Object(),
          const SessionGuidanceObservation(
              sessionId: 's',
              ownerUid: 'u',
              generation: 'g',
              eventId: 'e',
              text: 'information',
              synthetic: true),
          () => true,
          admission: admission);
      await t.pump();
      expect(output.commands, isEmpty);
      expect(tts.spoken, isEmpty);
      if (scenario == 'expired') await t.pump(const Duration(seconds: 4));
      if (scenario == 'epoch-changed') epoch++;
      receipt = LocalDirectionReceipt(
          sessionId: 's',
          ownerUid: 'u',
          generation: 'g',
          authEpoch: epoch,
          eventId: 'e',
          createdAt: DateTime.utc(2026, 10, 29),
          direction: TestDirection.left);
      pending.complete();
      await t.pump();
      if (scenario == 'ready') {
        expect(output.commands, ['CUE:left']);
        output.finish();
        await t.pump();
        expect(tts.spoken, ['information']);
        tts.finish();
        await t.pump();
        expect(await result, isTrue);
      } else {
        expect(await result, isFalse);
        expect(output.commands, isEmpty);
        expect(tts.spoken, isEmpty);
      }
      await engine.dispose();
      gate.dispose();
      await t.pump();
    });
  }
  testWidgets('diagnostic failure cannot block cancellation or engine cleanup',
      (t) async {
    final sink = f.FakeTts();
    // Use the exact sink owned by this coordinator.
    final owned = SpeechPriorityCoordinator(sink), owner = Object();
    var current = true;
    final admission = ObservationAdmission(
        deadlineMicros: 3000000,
        nowMicros: () => 0,
        eventId: 'e',
        sessionGeneration: 'g',
        receivedAt: '2026-10-29',
        trace: (_) => throw StateError('injected diagnostic failure'));
    final playing = SessionGuidanceAudio(priority: owned).speak(
        owner,
        const SessionGuidanceObservation(
            sessionId: 's',
            ownerUid: 'u',
            generation: 'g',
            eventId: 'e',
            text: 'information',
            synthetic: false),
        () => current,
        admission: admission);
    await t.pump();
    expect(sink.spoken, hasLength(1));
    current = false;
    admission.cancel('STOP');
    await owned.stopObservation(owner);
    await t.pump();
    expect(await playing, isFalse);
    expect(sink.playing!.isCompleted, isTrue);
    expect(admission.traceFailures, greaterThan(0));
    expect(admission.cancelReason, 'STOP');
    owned.dispose();
    await t.pump();
    expect(t.takeException(), isNull);
  });
}
