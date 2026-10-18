import 'dart:async';
import 'dart:typed_data';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/speech_request_scope.dart';
import 'package:mobi_passenger_app/src/services/audio_shutdown.dart';
import 'package:mobi_passenger_app/src/services/mock_script_audio_service.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'audio_lifecycle_test.dart' as lifecycle;
import 'vision_observation_tts_test.dart' as fixtures;

void main() {
  // These are the production receive/captureLatest calls used by V3's HTTP
  // boundary, including the originating request passed into audio/fallback.
  for (final end in [
    'stop',
    'reset',
    'logout',
    'uid',
    'session',
    'dispose',
    'replace route'
  ]) {
    test('route HTTP response after $end cannot publish, speak or fallback',
        () async {
      final scope = SpeechRequestScope(), page = SpeechRequestScope();
      var uid = 'a', session = 's', active = true;
      final owner = uid, sid = session;
      final speech = page.capture(() => uid == owner && session == sid);
      final request = scope.captureLatest(() => speech.valid && active);
      final response = Completer<String>();
      final actions = <String>[];
      final result = request.receive(() {
        actions.add('http');
        return response.future;
      }, (value) async {
        actions.add('publish:$value');
        await request.run(() async {
          actions.add('speak:$value');
        }, fallback: () async {
          actions.add('fallback:$value');
        });
      });
      if (end == 'logout' || end == 'uid') {
        uid = 'b';
        page.invalidate();
      } else if (end == 'session') {
        session = 'new';
      } else if (end == 'dispose') {
        page.dispose();
        scope.dispose();
      } else {
        scope.invalidate();
        if (end == 'stop') active = false;
        if (end == 'reset') page.invalidate();
      }
      response.complete('old');
      await result;
      expect(actions, ['http']);
    });
  }
  test('new HTTP result wins; old result cannot overwrite it or speak',
      () async {
    final scope = SpeechRequestScope();
    final old = scope.captureLatest(() => true);
    final oldResponse = Completer<String>();
    final actions = <String>[];
    Future<void> accept(SpeechRequest request, String value) async {
      actions.add('publish:$value');
      await request.run(() async {
        actions.add('speak:$value');
      });
    }

    final pending =
        old.receive(() => oldResponse.future, (v) => accept(old, v));
    final latest = scope.captureLatest(() => true);
    await latest.receive(() async => 'new', (v) => accept(latest, v));
    oldResponse.complete('old');
    await pending;
    expect(actions, ['publish:new', 'speak:new']);
  });
  test('invalidated HTTP error and cancelled audio never invoke fallback',
      () async {
    final scope = SpeechRequestScope();
    final old = scope.captureLatest(() => true);
    final response = Completer<String>();
    var fallback = 0, published = 0;
    final pending = old.run(
        () => old.receive(() => response.future, (_) async {
              published++;
            }), fallback: () async {
      fallback++;
    });
    scope.invalidate();
    response.completeError(StateError('transport'));
    await pending;
    final current = scope.captureLatest(() => true);
    await current.receive(
        () async => 'new',
        (_) => current.run(() async {
              throw SpeechCancelled();
            }, fallback: () async {
              fallback++;
            }));
    expect(fallback, 0);
    expect(published, 0);
  });
  test('same originating request gates delayed audio fallback after reset',
      () async {
    final scope = SpeechRequestScope();
    final request = scope.captureLatest(() => true);
    final failure = Completer<void>();
    var fallback = 0;
    final pending = request.receive(
        () async => 'route',
        (_) => request.run(() => failure.future, fallback: () async {
              fallback++;
            }));
    await Future<void>.delayed(Duration.zero);
    scope.invalidate();
    failure.completeError(StateError('audio'));
    await pending;
    expect(fallback, 0);
    // A genuinely new request retains normal error recovery.
    final next = scope.captureLatest(() => true);
    await next.run(() async {
      throw StateError('new error');
    }, fallback: () async {
      fallback++;
    });
    expect(fallback, 1);
  });
  testWidgets(
      'Clip dispose throw is reported; other cleanup runs independently',
      (t) async {
    final log = <String>[];
    final gate = SpeechPriorityCoordinator(fixtures.FakeTts());
    final player = lifecycle.FailingPlayer()..fail = true;
    final mock =
        MockScriptAudioService(audioPlayer: player, speechPriority: gate);
    var independent = false;
    final clip = observeAudioCleanup(() async {
      throw StateError('clip');
    }, channel: 'Clip', report: log.add);
    final other =
        observeAudioCleanup(mock.dispose, channel: 'Mock', report: log.add);
    final third = observeAudioCleanup(() async {
      independent = true;
    }, channel: 'Other', report: log.add);
    await t.pump();
    await Future.wait([clip, other, third]);
    expect(independent, true);
    expect(log, hasLength(2));
    expect(mock.shutdownConfirmed, false);
    expect(gate.priorityActive, true);
    expect(await gate.speakObservation(Object(), 'low', () => true), false);
    // Only confirmed output shutdown may release the retained priority.
    player.fail = false;
    await mock.stop();
    expect(gate.priorityActive, false);
    gate.dispose();
  });
  testWidgets(
      'hung Clip dispose is reported without blocking independent cleanup',
      (t) async {
    final clip = Completer<void>(), log = <String>[];
    var otherStopped = false;
    final pending = observeAudioCleanup(() => clip.future,
        channel: 'Clip', report: log.add);
    await observeAudioCleanup(() async {
      otherStopped = true;
    }, channel: 'Other', report: log.add);
    expect(otherStopped, true);
    await t.pump(const Duration(seconds: 4));
    await pending;
    expect(log.single, contains('Clip'));
    // Timeout is not a successful shutdown, nor a reason to mutate a new UI.
    clip.completeError(StateError('late native error'));
    await t.pump();
    expect(log, hasLength(1));
  });
  test('normal Clip cleanup completes without reporting failure', () async {
    final log = <String>[];
    await observeAudioCleanup(() async {}, channel: 'Clip', report: log.add);
    expect(log, isEmpty);
  });
  // Same production shutdown observer and real Cue service used by V3's
  // navigation stop callback. Native output alone is replaced by a Fake.
  for (final mode in ['normal', 'throw', 'hung']) {
    testWidgets(
        'navigation stop observes $mode shutdown without releasing unknown output',
        (t) async {
      final engine = fixtures.FakeTts();
      final gate = SpeechPriorityCoordinator(engine);
      final player = lifecycle.FailingPlayer();
      final service = AudioHapticCueService(
          speechPriority: gate,
          audioPlayer: player,
          liveAudioPlayer: fixtures.FakeLive());
      await service.playGeneratedSpeech(Uint8List.fromList([0]));
      expect(gate.priorityActive, true);
      final scope = SpeechRequestScope();
      final request = scope.captureLatest(() => true);
      final http = Completer<String>();
      var publish = 0, fallback = 0;
      final response = request.receive(() => http.future, (_) async {
        publish++;
        await request.run(() async {
          throw StateError('old audio');
        }, fallback: () async {
          fallback++;
        });
      });
      if (mode == 'throw') player.fail = true;
      if (mode == 'hung') player.stopping = Completer<void>();
      // V3 invalidates its route scope synchronously before observing stop.
      scope.invalidate();
      final log = <String>[];
      final stopped = observeAudioCleanup(service.stopCue,
          channel: '길찾기 음성', report: log.add);
      http.complete('old route');
      await response;
      await t.pump();
      if (mode == 'hung') await t.pump(const Duration(seconds: 4));
      await stopped;
      expect(publish, 0);
      expect(fallback, 0);
      expect(t.takeException(), isNull);
      if (mode == 'normal') {
        expect(log, isEmpty);
        expect(service.shutdownConfirmed, true);
        expect(gate.priorityActive, false);
      } else {
        expect(log, hasLength(1));
        expect(log.single, '길찾기 음성 종료를 확인하지 못했습니다. 출력 장치를 확인해 주세요.');
        expect(service.shutdownConfirmed, false);
        expect(gate.priorityActive, true);
        expect(await gate.speakObservation(Object(), 'low', () => true), false);
        player.fail = false;
        if (mode == 'hung') {
          player.stopping!.complete();
          await t.pump();
        }
        await service.stopCue();
        expect(service.shutdownConfirmed, true);
        expect(gate.priorityActive, false);
      }
      // A confirmed recovery permits a new valid playback, not old fallback.
      await service.playGeneratedSpeech(Uint8List.fromList([1]));
      expect(player.starts, 2);
      expect(gate.priorityActive, true);
      await service.stopCue();
      expect(gate.priorityActive, false);
      await service.dispose();
      gate.dispose();
    });
  }
}
