import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/mock_scenario/mock_scenario_controller.dart';
import 'package:mobi_passenger_app/src/services/audio_shutdown.dart';
import 'package:mobi_passenger_app/src/services/mock_script_audio_service.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'vision_observation_tts_test.dart' as fixtures;

void main() {
  for (final action in ['pause', 'reset', 'switch', 'dispose']) {
    testWidgets(
        'Controller $action observes late Clip cancellation without retry',
        (t) async {
      final completion = Completer<void>();
      var calls = 0;
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      final controller = MockScenarioController(onScriptLine: (_, __, ___) {
        calls++;
        return completion.future;
      });
      var disposed = false;
      try {
        controller.play();
        expect(calls, 1);
        switch (action) {
          case 'pause':
            controller.pause();
            break;
          case 'reset':
            controller.reset();
            break;
          case 'switch':
            controller.nextScenario();
            break;
          case 'dispose':
            controller.dispose();
            disposed = true;
            break;
        }
        completion.completeError(SpeechCancelled());
        await t.pump();
        expect(errors, isEmpty);
        expect(t.takeException(), isNull);
        expect(calls, 1); // No retry or fallback from the controller.
      } finally {
        if (!disposed) controller.dispose();
        await t.pump();
        FlutterError.onError = old;
      }
    });
  }
  for (final mode in ['sync', 'async', 'shutdown']) {
    testWidgets(
        'Controller reports $mode failure with original stack, including retired callbacks',
        (t) async {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      final completion = Completer<void>();
      final Object error = mode == 'shutdown'
          ? AudioShutdownFailure(StateError('output not stopped'))
          : StateError('playback failed');
      final stack = StackTrace.current;
      final controller = MockScenarioController(onScriptLine: (_, __, ___) {
        if (mode == 'sync') Error.throwWithStackTrace(error, stack);
        return completion.future;
      });
      try {
        controller.play();
        controller.pause();
        if (mode != 'sync') completion.completeError(error, stack);
        await t.pump();
        expect(errors, hasLength(1));
        expect(identical(errors.single.exception, error), true);
        expect(errors.single.stack.toString(), stack.toString());
        expect(errors.single.library, 'mock scenario audio');
        expect(t.takeException(), isNull);
      } finally {
        controller.dispose();
        await t.pump();
        FlutterError.onError = old;
      }
    });
  }
  testWidgets(
      'Cue and independent stop callbacks observe cancellation and report real failure',
      (t) async {
    final errors = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = errors.add;
    final stopError = StateError('stop failed');
    final controller = MockScenarioController(
      onCueFrame: (_) => Future<void>.error(SpeechCancelled()),
      onStopCue: () => Future<void>.error(stopError),
      onStopScriptAudio: () => Future<void>.error(SpeechCancelled()),
    );
    try {
      controller.play();
      await t.pump();
      expect(errors, isEmpty);
      controller.pause();
      await t.pump();
      expect(errors, hasLength(1));
      expect(errors.single.exception, same(stopError));
      expect(t.takeException(), isNull);
      controller.dispose();
      await t.pump();
      expect(errors, hasLength(2));
    } finally {
      FlutterError.onError = old;
    }
  });
  testWidgets(
      'Real Controller and Clip service preempt Observation, cancel repeatedly, then permit new Observation',
      (t) async {
    final engine = fixtures.FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final clips = <Completer<bool>>[];
    final service = MockScriptAudioService(
      speechPriority: gate,
      audioPlayer: fixtures.FakePlayer(),
      webClipPlayer: (_, __, ___) {
        final clip = Completer<bool>();
        clips.add(clip);
        return clip.future;
      },
      webClipStop: () async {
        for (final clip in clips) {
          if (!clip.isCompleted) clip.complete(false);
        }
      },
    );
    final controller = MockScenarioController(
      onScriptLine: (id, message, _) =>
          service.playScript(id, fallbackText: message),
      onStopScriptAudio: service.stop,
    );
    controller.selectScenario('s07_danger_zone');
    await t.pump();
    final lowOwner = Object();
    final low = gate.speakObservation(lowOwner, '관찰', () => true);
    await t.pump();
    expect(engine.spoken, ['관찰']);
    for (var i = 0; i < 3; i++) {
      controller.play();
      await t.pump();
      expect(gate.priorityActive, true);
      expect(clips.length, i + 1);
      expect(
          await gate.speakObservation(lowOwner, '끼어들면 안 됨', () => true), false);
      controller.reset();
      await t.pump();
      expect(gate.priorityActive, false);
      expect(service.shutdownConfirmed, true);
      expect(t.takeException(), isNull);
    }
    expect(await low, false);
    expect(engine.spoken,
        ['관찰']); // Cancelled Clips never replay via TTS fallback.
    final next = gate.speakObservation(lowOwner, '새 관찰', () => true);
    await t.pump();
    expect(engine.spoken.last, '새 관찰');
    engine.finish();
    await t.pump();
    expect(await next, true);
    controller.dispose();
    await t.pump();
    await service.dispose();
    gate.dispose();
  });
}
