import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/pages/local_spatial_verification_page.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'vision_observation_tts_test.dart' as f;
import 'local_spatial_verification_test.dart' as spatial;

class CueOutput extends spatial.Output implements DirectionalCueOutput {
  Completer<void>? stopGate;
  bool failCue = false, failClose = false;
  @override
  Future<bool> playCue(TestDirection d) {
    if (failCue) throw StateError('cue failed');
    return play('CUE', d.name);
  }

  @override
  Future<void> stop() async {
    await stopGate?.future;
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    if (failClose) throw StateError('close failed');
    await super.dispose();
  }
}

DirectionalGuidance message(
        {String id = 'g1',
        String generation = 'gen1',
        int epoch = 1,
        TestDirection? direction = TestDirection.left,
        String provenance = DirectionalGuidance.syntheticProvenance,
        DirectionEvidence evidence = DirectionEvidence.explicitLocalFixture}) =>
    DirectionalGuidance(
        guidanceId: id,
        sessionGeneration: generation,
        authEpoch: epoch,
        priority: GuidancePriority.observation,
        text: '순차 안내 검증입니다.',
        provenance: provenance,
        testDirection: direction,
        directionEvidence: evidence);
void main() {
  for (final scenario in [
    'sequence',
    'stop-cue',
    'stop-tts',
    'hold-cue',
    'cue-failure',
    'tts-failure',
    'stop-failure',
    'lost-callback',
    'generation-change',
    'dispose'
  ]) {
    testWidgets('one guidance run $scenario', (t) async {
      final output = CueOutput(), tts = f.FakeTts(), trace = <String>[];
      final engine = SpatialVerificationEngine(output, tts,
          onGuidanceTrace: (_, p) => trace.add(p));
      final gate = SpeechPriorityCoordinator(engine);
      final owner = Object();
      var current = true;
      bool valid() => current && !gate.priorityActive;
      final g = message();
      final command = engine.registerGuidance(g, valid)!;
      if (scenario == 'cue-failure') output.failCue = true;
      final playing = gate.speakObservation(owner, command, valid);
      final expectation = (scenario == 'cue-failure' ||
              scenario == 'tts-failure' ||
              scenario == 'stop-failure')
          ? expectLater(playing, throwsStateError)
          : scenario == 'lost-callback'
              ? expectLater(playing, throwsA(isA<TimeoutException>()))
              : (scenario == 'generation-change' || scenario == 'dispose')
                  ? expectLater(playing, throwsA(isA<SpeechCancelled>()))
                  : null;
      await t.pump();
      if (scenario == 'cue-failure') {
        await expectation;
        expect(tts.spoken, isEmpty);
      } else {
        expect(output.commands, ['CUE:left']);
        expect(tts.spoken, isEmpty);
        if (scenario == 'sequence') {
          output.stopGate = Completer<void>();
          output.finish();
          await t.pump();
          expect(tts.spoken, isEmpty);
          expect(trace, contains('CUE_COMPLETED'));
          output.stopGate!.complete();
          await t.pump();
          expect(tts.spoken.single, startsWith('검증용 합성 안내입니다.'));
          expect(trace, [
            'CUE_START',
            'CUE_COMPLETED',
            'CUE_STOP_CONFIRMED',
            'TTS_START'
          ]);
          tts.finish();
          await t.pump();
          expect(await playing, true);
          expect(trace.last, 'TTS_COMPLETED');
        } else if (scenario == 'tts-failure') {
          tts.fail = true;
          output.finish();
          await t.pump();
          await expectation;
          expect(tts.spoken, isEmpty);
        } else if (scenario == 'stop-failure') {
          output.failStop = true;
          output.finish();
          await t.pump();
          await expectation;
          expect(gate.priorityActive, true);
          expect(tts.spoken, isEmpty);
          output.failStop = false;
        } else if (scenario == 'lost-callback') {
          await t.pump(const Duration(seconds: 31));
          await expectation;
          expect(tts.spoken, isEmpty);
          expect(output.pending.every((p) => p.isCompleted), true);
        } else if (scenario == 'hold-cue') {
          final lease = gate.claimPriority();
          await t.pump();
          expect(await playing, false);
          lease.release();
          output.finish();
          await t.pump();
          expect(tts.spoken, isEmpty);
          expect(engine.registerGuidance(g, valid), isNull);
        } else if (scenario == 'generation-change') {
          current = false;
          output.finish();
          await t.pump();
          await expectation;
          expect(tts.spoken, isEmpty);
          current = true;
          final next = message(generation: 'gen2');
          expect(engine.registerGuidance(next, valid), isNotNull);
        } else if (scenario == 'dispose') {
          await engine.dispose();
          await t.pump();
          expect(output.disposed, true);
          await expectation;
          expect(tts.spoken, isEmpty);
        } else {
          if (scenario == 'stop-tts') {
            output.finish();
            await t.pump();
            expect(tts.spoken.length, 1);
          }
          await gate.stopObservation(owner);
          await t.pump();
          expect(await playing, false);
          output.finish();
          tts.finish();
          await t.pump();
          expect(tts.spoken.length, scenario == 'stop-tts' ? 1 : 0);
        }
      }
      await engine.dispose();
      gate.dispose();
    });
  }
  for (final kind in [
    'no-direction',
    'unknown-provenance',
    'unverified-direction'
  ]) {
    testWidgets('only ordinary TTS when $kind', (t) async {
      final output = CueOutput(), tts = f.FakeTts();
      final engine = SpatialVerificationEngine(output, tts);
      final gate = SpeechPriorityCoordinator(engine);
      final g = message(
          direction: kind == 'no-direction' ? null : TestDirection.right,
          provenance: kind == 'unknown-provenance'
              ? 'UNKNOWN'
              : DirectionalGuidance.syntheticProvenance,
          evidence: kind == 'unverified-direction'
              ? DirectionEvidence.unverified
              : DirectionEvidence.explicitLocalFixture);
      final command = engine.registerGuidance(g, () => true)!;
      final playing = gate.speakObservation(Object(), command, () => true);
      await t.pump();
      expect(output.commands, isEmpty);
      expect(tts.spoken.length, 1);
      tts.finish();
      await t.pump();
      expect(await playing, true);
      await engine.dispose();
      gate.dispose();
    });
  }
  test(
      'same scoped guidance ID is refused before preemption; distinct epoch allowed',
      () async {
    final e = SpatialVerificationEngine(CueOutput(), f.FakeTts());
    final g = message();
    expect(e.registerGuidance(g, () => true), isNotNull);
    expect(e.registerGuidance(g, () => true), isNull);
    expect(e.registerGuidance(message(epoch: 2), () => true), isNotNull);
    expect(e.registerGuidance(message(id: 'stale'), () => false), isNull);
    await e.dispose();
    expect(e.registerGuidance(message(id: 'later'), () => true), isNull);
  });
  test('close error is propagated and retired engine refuses new work',
      () async {
    final output = CueOutput()..failClose = true;
    final e = SpatialVerificationEngine(output, f.FakeTts());
    await expectLater(e.dispose(), throwsStateError);
    expect(e.registerGuidance(message(), () => true), isNull);
  });
  testWidgets('retired epoch during TTS prepare cannot cross the Cue boundary',
      (t) async {
    final output = CueOutput(),
        tts = f.FakeTts()..preparing = Completer<void>();
    final engine = SpatialVerificationEngine(output, tts);
    final gate = SpeechPriorityCoordinator(engine);
    var current = true;
    final command = engine.registerGuidance(message(), () => current)!;
    final result = gate.speakObservation(Object(), command, () => current);
    final cancelled = expectLater(result, throwsA(isA<SpeechCancelled>()));
    await t.pump();
    output.finish();
    await t.pump();
    expect(tts.spoken, isEmpty);
    current = false;
    tts.preparing!.complete();
    await t.pump();
    await cancelled;
    expect(tts.spoken, isEmpty);
    await engine.dispose();
    gate.dispose();
  });
  testWidgets('synchronous priority claim at TTS boundary cannot start old TTS',
      (t) async {
    final output = CueOutput(), tts = f.FakeTts();
    SpeechPriorityCoordinator? gate;
    PriorityLease? hold;
    final engine =
        SpatialVerificationEngine(output, tts, onGuidanceTrace: (_, phase) {
      if (phase == 'TTS_START') hold = gate!.claimPriority();
    });
    gate = SpeechPriorityCoordinator(engine);
    bool valid() => !gate!.priorityActive;
    final command = engine.registerGuidance(message(), valid)!;
    Object? cancellation;
    final result = gate
        .speakObservation(Object(), command, valid)
        .then((v) => v, onError: (Object error) {
      cancellation = error;
      return false;
    });
    await t.pump();
    output.finish();
    await t.pump();
    expect(await result, false);
    expect(cancellation, isA<SpeechCancelled>());
    expect(tts.spoken, isEmpty);
    hold?.release();
    await engine.dispose();
    gate.dispose();
  });
  for (final scenario in [
    'sequence',
    'duplicate',
    'rapid',
    'hold-cue',
    'hold-tts',
    'end',
    'reset',
    'logout',
    'dispose',
    'page-exit'
  ]) {
    testWidgets('Guidance page $scenario', (t) async {
      t.view.physicalSize = const Size(1600, 2400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final output = CueOutput(), tts = f.FakeTts();
      await t.pumpWidget(MaterialApp(
          home: LocalSpatialVerificationPage(
              enabled: true,
              output: output,
              tts: tts,
              cuesFactory: (p) => AudioHapticCueService(
                  speechPriority: p,
                  audioPlayer: f.FakePlayer(),
                  liveAudioPlayer: f.FakeLive()))));
      await t.tap(find.text('LEFT Cue → TTS'));
      await t.pump();
      expect(output.commands, ['CUE:left']);
      expect(tts.spoken, isEmpty);
      if (scenario == 'duplicate') {
        await t.tap(find.text('직전 guidanceId 재전송'));
        await t.pump();
        expect(output.commands.length, 1);
        expect(
            find.textContaining('DUPLICATE_GUIDANCE_IGNORED'), findsOneWidget);
        output.finish();
        await t.pump();
        expect(tts.spoken.length, 1);
        tts.finish();
        await t.pump();
      } else if (scenario == 'rapid') {
        await t.tap(find.text('RIGHT Cue → TTS'));
        await t.pump();
        expect(output.commands, ['CUE:left', 'CUE:right']);
        output.finish();
        await t.pump();
        expect(tts.spoken.length, 1);
        expect(find.text('local-guidance-1 TTS_START'), findsNothing);
        tts.finish();
        await t.pump();
      } else if (scenario == 'sequence') {
        output.finish();
        await t.pump();
        expect(tts.spoken.length, 1);
        tts.finish();
        await t.pump();
        expect(find.textContaining('GUIDANCE_COMPLETED'), findsOneWidget);
      } else if (scenario == 'hold-cue' || scenario == 'hold-tts') {
        if (scenario == 'hold-tts') {
          output.finish();
          await t.pump();
        }
        await t.tap(find.text('Live Hold 선점'));
        await t.pump();
        expect(tts.spoken.length, scenario == 'hold-tts' ? 2 : 1);
        expect(tts.spoken.last, startsWith('검증용 Live Hold'));
        output.finish();
        await t.pump();
        expect(tts.spoken.length, scenario == 'hold-tts' ? 2 : 1);
        tts.finish();
        await t.pump();
      } else if (scenario == 'page-exit') {
        await t.tap(find.text('페이지 종료'));
        output.finish();
        await t.pump();
        expect(tts.spoken, isEmpty);
        await t.pumpAndSettle();
        await t.pump();
        expect(output.disposed, true);
        expect(tts.spoken, isEmpty);
      } else if (scenario == 'dispose') {
        await t.pumpWidget(const SizedBox());
        await t.pump();
        expect(output.disposed, true);
        output.finish();
        await t.pump();
        expect(tts.spoken, isEmpty);
      } else {
        await t.tap(find.text(scenario == 'end'
            ? '세션 종료'
            : scenario == 'logout'
                ? '로그아웃'
                : 'Reset / 새 generation'));
        await t.pump();
        output.finish();
        await t.pump();
        expect(tts.spoken, isEmpty);
        if (scenario == 'reset') {
          await t.tap(find.text('직전 guidanceId 재전송'));
          await t.pump();
          expect(find.text('OLD_GUIDANCE_SCOPE_REJECTED'), findsOneWidget);
          await t.tap(find.text('RIGHT Cue → TTS'));
          await t.pump();
          expect(output.commands.last, 'CUE:right');
        }
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
    });
  }
}
