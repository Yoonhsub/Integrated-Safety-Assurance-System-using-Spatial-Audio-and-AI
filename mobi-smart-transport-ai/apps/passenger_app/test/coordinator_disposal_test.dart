import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'package:mobi_passenger_app/src/pages/local_spatial_verification_page.dart';
import 'vision_observation_tts_test.dart' as f;
import 'local_spatial_verification_test.dart' as spatial;

class DelayedPlayer extends f.FakePlayer {
  final stopping = Completer<void>();
  @override
  Future<void> stop() => stopping.future;
}

class DelayedEngine extends f.FakeTts {
  final stopping = Completer<void>();
  @override
  Future<void> stop() async {
    stops++;
    await stopping.future;
    finish();
  }
}

void main() {
  test(
      'active lease notifies normally; retired leases are inactive and idempotent',
      () async {
    final gate = SpeechPriorityCoordinator(f.FakeTts());
    var notifications = 0;
    gate.addListener(() => notifications++);
    final first = gate.claimPriority();
    expect(notifications, 1);
    first.release();
    first.release();
    expect(notifications, 2);
    expect(gate.priorityActive, false);
    final late = gate.claimPriority();
    final before = notifications;
    gate.dispose();
    gate.dispose();
    expect(late.active, false);
    late.release();
    late.release();
    expect(notifications, before);
    expect(gate.priorityActive, true);
    expect(() => gate.claimPriority(), throwsA(isA<SpeechCancelled>()));
    expect(await gate.speakObservation(Object(), 'new', () => true), false);
  });
  testWidgets('dispose during prepare blocks later native start', (t) async {
    final engine = f.FakeTts()..preparing = Completer<void>();
    final gate = SpeechPriorityCoordinator(engine);
    final result = gate.speakObservation(Object(), 'old', () => true);
    await t.pump();
    gate.dispose();
    engine.preparing!.complete();
    await t.pump();
    expect(await result, false);
    expect(engine.spoken, isEmpty);
  });
  testWidgets(
      'late native stop failure remains observable without disposed notification',
      (t) async {
    final engine = DelayedEngine();
    final current = SpeechPriorityCoordinator(engine);
    var notifications = 0;
    current.addListener(() => notifications++);
    final playing = current.speakObservation(Object(), 'old', () => true);
    await t.pump();
    final failure = expectLater(playing, throwsStateError);
    current.dispose();
    await t.pump();
    final after = notifications;
    engine.stopping.completeError(StateError('native stop failed'));
    await t.pump();
    await failure;
    expect(notifications, after);
    expect(t.takeException(), isNull);
  });
  for (final outcome in ['success', 'failure']) {
    for (final timing in ['dispose-first', 'timeout-first', 'hold']) {
      testWidgets('native stop $outcome after $timing keeps new page isolated',
          (t) async {
        t.view.physicalSize = const Size(1600, 2000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final oldOutput = spatial.Output(),
            oldTts = f.FakeTts(),
            player = DelayedPlayer();
        SpeechPriorityCoordinator? oldGate;
        var notifications = 0;
        var cleanupErrors = 0;
        Widget page(Key key, spatial.Output output, f.FakeTts tts,
                {DelayedPlayer? slow}) =>
            MaterialApp(
                home: LocalSpatialVerificationPage(
                    key: key,
                    enabled: true,
                    output: output,
                    tts: tts,
                    cuesFactory: (g) {
                      if (slow != null) {
                        oldGate = g;
                        g.addListener(() => notifications++);
                      }
                      return AudioHapticCueService(
                          speechPriority: g,
                          audioPlayer: slow ?? f.FakePlayer(),
                          liveAudioPlayer: f.FakeLive(),
                          onAudioError: (_) => cleanupErrors++);
                    }));
        await t.pumpWidget(
            page(const ValueKey('old'), oldOutput, oldTts, slow: player));
        await t.tap(find.text('STEREO LEFT'));
        await t.pump();
        expect(oldOutput.commands.length, 1);
        if (timing == 'hold') {
          await t.tap(find.text('Live Hold 선점'));
          await t.pump();
          expect(oldTts.spoken.length, 1);
        }
        if (timing == 'timeout-first') {
          await t.tap(find.text('STOP'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 3100));
        }
        final nextOutput = spatial.Output(), nextTts = f.FakeTts();
        await t.pumpWidget(page(const ValueKey('new'), nextOutput, nextTts));
        await t.pump(const Duration(milliseconds: 3100));
        await t.pump();
        expect(oldOutput.disposed, true);
        expect(oldOutput.pending.every((p) => p.isCompleted), true);
        expect(cleanupErrors, greaterThan(0));
        await t.tap(find.text('HRTF RIGHT'));
        await t.pump();
        expect(nextOutput.commands, ['HRTF:RIGHT']);
        final after = notifications;
        final activeNext = nextOutput.pending.last;
        if (outcome == 'success') {
          player.stopping.complete();
        } else {
          player.stopping.completeError(StateError('late native stop failed'));
        }
        await t.pump();
        await t.pump();
        expect(notifications, after);
        expect(t.takeException(), isNull);
        expect(nextOutput.commands.length, 1);
        expect(activeNext.isCompleted, false);
        expect(oldGate!.priorityActive, true);
        oldTts.finish();
        await t.pump();
        expect(activeNext.isCompleted, false);
        await t.pumpWidget(const SizedBox());
        await t.pump();
      });
    }
  }
  testWidgets(
      'normal stop/dispose and rapid repeated release preserve live notifications',
      (t) async {
    final engine = f.FakeTts();
    final current = SpeechPriorityCoordinator(engine);
    var notices = 0;
    current.addListener(() => notices++);
    for (var i = 0; i < 10; i++) {
      final lease = current.claimPriority();
      lease.release();
      lease.release();
    }
    expect(notices, 20);
    expect(current.priorityActive, false);
    final owner = Object();
    final playing = current.speakObservation(owner, 'normal', () => true);
    await t.pump();
    await current.stopObservation(owner);
    await t.pump();
    expect(await playing, false);
    current.dispose();
    current.dispose();
    expect(t.takeException(), isNull);
  });
}
