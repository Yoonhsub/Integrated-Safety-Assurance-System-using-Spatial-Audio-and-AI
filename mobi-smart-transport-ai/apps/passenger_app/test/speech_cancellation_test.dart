import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/speech_request_scope.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'package:mobi_passenger_app/src/services/mock_script_audio_service.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'vision_observation_tts_test.dart' as fixtures;

class ChannelFeedback implements CueFeedback {
  Completer<void>? vibration, beepDelay;
  bool failVibration = false, failBeep = false;
  int beeps = 0, vibrations = 0;
  @override
  Future<void> vibrate({required bool heavy}) async {
    vibrations++;
    if (failVibration) throw StateError('vibration');
    await vibration?.future;
  }

  @override
  Future<void> beep() async {
    beeps++;
    if (failBeep) throw StateError('beep');
    await beepDelay?.future;
  }
}

class CancellableLive extends fixtures.FakeLive {
  Completer<void>? active;
  @override
  Future<void> play(
      {required String baseUrl,
      required String text,
      void Function()? onFirstAudio}) {
    active = Completer<void>();
    return active!.future;
  }

  @override
  Future<void> stop() async {
    final retired = active;
    active = null;
    if (retired != null && !retired.isCompleted) {
      retired.completeError(SpeechCancelled());
    }
  }
}

const danger = V3Cue(
    type: 'DANGER',
    ttsMode: 'SAFETY_LOCAL',
    shouldBeep: true,
    shouldVibrate: true,
    message: '위험');
void main() {
  test('explicit cancellation never invokes fallback; real failure still does',
      () async {
    final scope = SpeechRequestScope();
    var fallbacks = 0;
    await scope.capture(() => true).run(() async {
      throw SpeechCancelled();
    }, fallback: () async {
      fallbacks++;
    });
    expect(fallbacks, 0);
    await scope.capture(() => true).run(() async {
      throw StateError('failure');
    }, fallback: () async {
      fallbacks++;
    });
    expect(fallbacks, 1);
  });
  for (final end in ['session end', 'logout', 'session change', 'dispose']) {
    test('late previous request cannot fall back after $end', () async {
      final scope = SpeechRequestScope();
      var uid = 'a', session = 's', spoken = 0;
      final owner = uid, sid = session;
      final request = scope.capture(() => uid == owner && session == sid);
      final response = Completer<void>();
      final pending = request.run(() => response.future, fallback: () async {
        spoken++;
      });
      if (end == 'dispose') {
        scope.dispose();
      } else if (end == 'logout') {
        uid = 'b';
      } else if (end == 'session change') {
        session = 'new';
      } else {
        scope.invalidate();
      }
      response.completeError(StateError('old transport failed'));
      await pending;
      expect(spoken, 0);
      await request.run(() async {
        spoken++;
      });
      expect(spoken, 0);
    });
  }
  test(
      'late successful HTTP result is checked before audio and old completion cannot invalidate new scope',
      () async {
    final scope = SpeechRequestScope();
    var played = 0;
    final response = Completer<void>();
    final old = scope.capture(() => true);
    final pending = old.run(() async {
      await response.future;
      old.check();
      played++;
    });
    scope.invalidate();
    final next = scope.capture(() => true);
    response.complete();
    await pending;
    expect(played, 0);
    await next.run(() async {
      played++;
    });
    expect(played, 1);
  });
  testWidgets(
      'hung vibration cannot block immediate and repeated beep, including new danger',
      (t) async {
    final feedback = ChannelFeedback()..vibration = Completer<void>();
    final gate = SpeechPriorityCoordinator(fixtures.FakeTts());
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    final start = service.playCue(danger, speakMessage: false);
    await t.pump();
    expect(feedback.beeps, 1);
    expect(feedback.vibrations, 1);
    await t.pump(const Duration(milliseconds: 1100));
    await start;
    expect(feedback.beeps, greaterThan(1));
    expect(feedback.vibrations, 1);
    await service.playCue(
        const V3Cue(
            type: 'WRONG_BUS_NEAR',
            ttsMode: 'SAFETY_LOCAL',
            shouldBeep: true,
            shouldVibrate: true),
        speakMessage: false);
    expect(feedback.beeps, greaterThan(2));
    expect(feedback.vibrations, 1);
    await service.dispose();
    final count = feedback.beeps;
    feedback.vibration!.complete();
    await t.pump(const Duration(seconds: 3));
    expect(feedback.beeps, count);
    gate.dispose();
  });
  testWidgets(
      'vibration failure and beep failure do not block the other channel',
      (t) async {
    final feedback = ChannelFeedback()..failVibration = true;
    final gate = SpeechPriorityCoordinator(fixtures.FakeTts());
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    await service.playCue(danger, speakMessage: false);
    expect(feedback.beeps, 1);
    feedback.failVibration = false;
    feedback.failBeep = true;
    await t.pump(const Duration(milliseconds: 900));
    expect(feedback.vibrations, 2);
    await service.dispose();
    gate.dispose();
  });
  testWidgets('hung beep cannot block repeating vibration', (t) async {
    final feedback = ChannelFeedback()..beepDelay = Completer<void>();
    final gate = SpeechPriorityCoordinator(fixtures.FakeTts());
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    final start = service.playCue(danger, speakMessage: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 1100));
    await start;
    expect(feedback.vibrations, greaterThan(1));
    expect(feedback.beeps, 1);
    await service.dispose();
    feedback.beepDelay!.complete();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'disposed voice services refuse late fallback or generated playback',
      (t) async {
    final engine = fixtures.FakeTts(),
        gate = SpeechPriorityCoordinator(fixtures.FakeTts());
    final own = SpeechPriorityCoordinator(engine);
    final service = AudioHapticCueService(
        speechPriority: own,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    final mock = MockScriptAudioService(
        speechPriority: own, audioPlayer: fixtures.FakePlayer());
    await service.dispose();
    await mock.dispose();
    await expectLater(
        service.speakLocal('old'), throwsA(isA<SpeechCancelled>()));
    await expectLater(mock.speakText('old'), throwsA(isA<SpeechCancelled>()));
    expect(engine.spoken, isEmpty);
    own.dispose();
    gate.dispose();
  });
  testWidgets(
      'actual service cancellation reaches fallback policy without replay',
      (t) async {
    final gate = SpeechPriorityCoordinator(fixtures.FakeTts()),
        live = CancellableLive();
    final service = AudioHapticCueService(
        speechPriority: gate,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: live);
    final scope = SpeechRequestScope();
    var fallback = 0;
    final playing = scope.capture(() => true).run(
        () => service.playLiveGeneratedSpeech(
            baseUrl: 'http://localhost', text: '위험'), fallback: () async {
      fallback++;
    });
    await t.pump();
    expect(gate.priorityActive, isTrue);
    await service.stopCue();
    await playing;
    expect(fallback, 0);
    expect(gate.priorityActive, isFalse);
    await service.dispose();
    gate.dispose();
  });
  testWidgets(
      'missing completion times out, releases after stop and accepts next valid warning',
      (t) async {
    final engine = fixtures.FakeTts(),
        gate = SpeechPriorityCoordinator(fixtures.FakeTts());
    final own = SpeechPriorityCoordinator(engine), owner = Object();
    final lease = own.claimPriority();
    final expired = expectLater(own.speakPriority(owner, 'old', () => true),
        throwsA(isA<TimeoutException>()));
    await t.pump();
    await t.pump(const Duration(seconds: 31));
    await t.pump();
    await expired;
    lease.release();
    expect(own.priorityActive, isFalse);
    final nextLease = own.claimPriority();
    final next = own.speakPriority(owner, 'new', () => true);
    await t.pump();
    expect(engine.spoken, ['old', 'new']);
    engine.finish();
    await t.pump();
    expect(await next, isTrue);
    nextLease.release();
    own.dispose();
    gate.dispose();
  });
}
