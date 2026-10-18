import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/live_audio_session.dart';
import 'package:mobi_passenger_app/src/services/audio_shutdown.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'package:mobi_passenger_app/src/services/mock_script_audio_service.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/speech_request_scope.dart';
import 'vision_observation_tts_test.dart' as f;

class Output implements LiveAudioOutput {
  Completer<void>? stopping;
  bool fail = false;
  int starts = 0, feeds = 0, stops = 0;
  final drains = <Completer<bool>>[];
  @override
  Future<void> prepare() async {}
  @override
  void start(int rate) {
    starts++;
  }

  @override
  void feed(String pcm) {
    feeds++;
  }

  @override
  Future<bool> finish() {
    final d = Completer<bool>();
    drains.add(d);
    return d.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (fail) throw StateError('stop');
    await stopping?.future;
  }
}

class Socket implements LiveAudioConnection {
  @override
  late void Function() onOpen, onError, onClose;
  @override
  late void Function(Object?) onMessage;
  int sends = 0, closes = 0;
  @override
  void send(String text) {
    sends++;
  }

  @override
  void close() {
    closes++;
  }

  void audio() => onMessage('{"type":"audio","data":"AAAA"}');
  void done() => onMessage('{"type":"done"}');
}

class Harness {
  final output = Output();
  final sockets = <Socket>[];
  late final session = LiveAudioSession(
      output: output,
      connect: (_) {
        final socket = Socket();
        sockets.add(socket);
        return socket;
      });
}

class FailingPlayer extends f.FakePlayer {
  bool fail = false, failPlay = false;
  Completer<void>? stopping, starting;
  int stops = 0, starts = 0;
  @override
  Future<void> stop() async {
    stops++;
    if (fail) throw StateError('native stop');
    await stopping?.future;
  }

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #play) {
      starts++;
      if (failPlay) return Future<void>.error(StateError('native play'));
      return starting?.future ?? Future<void>.value();
    }
    return super.noSuchMethod(i);
  }
}

void main() {
  for (final why in ['cancel', 'logout', 'dispose']) {
    testWidgets(
        'startup shutdown pending then $why creates no socket or output',
        (t) async {
      final h = Harness();
      h.output.stopping = Completer<void>();
      final retired = expectLater(
          h.session.play(baseUrl: 'http://local', text: 'old'),
          throwsA(isA<SpeechCancelled>()));
      await t.pump();
      expect(h.session.state, LiveAudioState.starting);
      final stop = why == 'dispose' ? h.session.dispose() : h.session.stop();
      expect(h.session.state, LiveAudioState.cancelling);
      h.output.stopping!.complete();
      await t.pump();
      await stop;
      await retired;
      expect(h.sockets, isEmpty);
      expect(h.output.starts, 0);
      expect(h.session.state, LiveAudioState.cancelled);
    });
  }
  testWidgets(
      'cancel immediately after startup stop settles still rejects old start',
      (t) async {
    final h = Harness();
    h.output.stopping = Completer<void>();
    final old = expectLater(
        h.session.play(baseUrl: 'http://local', text: 'old'),
        throwsA(isA<SpeechCancelled>()));
    h.output.stopping!.complete();
    final stop = h.session.stop();
    await t.pump();
    await old;
    await stop;
    expect(h.sockets, isEmpty);
  });
  testWidgets(
      'cancel connecting socket rejects late open/audio and allows new request',
      (t) async {
    final h = Harness();
    final old = expectLater(
        h.session.play(baseUrl: 'http://local', text: 'old'),
        throwsA(isA<SpeechCancelled>()));
    await t.pump();
    final socket = h.sockets.single;
    await h.session.stop();
    await old;
    socket.onOpen();
    socket.audio();
    socket.onError();
    socket.onClose();
    expect(socket.sends, 0);
    expect(h.output.feeds, 0);
    final next = h.session.play(baseUrl: 'http://local', text: 'new');
    await t.pump();
    h.sockets.last.onOpen();
    h.sockets.last.audio();
    expect(h.session.state, LiveAudioState.playing);
    expect(h.output.feeds, 1);
    h.sockets.last.done();
    h.output.drains.last.complete(true);
    await next;
    expect(h.session.state, LiveAudioState.completed);
  });
  testWidgets('first audio callback cancellation prevents actual PCM output',
      (t) async {
    final h = Harness();
    Future<void>? stopping;
    final old = expectLater(
        h.session.play(
            baseUrl: 'http://local',
            text: 'old',
            onFirstAudio: () {
              stopping = h.session.stop();
            }),
        throwsA(isA<SpeechCancelled>()));
    await t.pump();
    h.sockets.single.onOpen();
    h.sockets.single.audio();
    await t.pump();
    await stopping;
    await old;
    expect(h.output.feeds, 0);
  });
  testWidgets('old drain completion cannot complete or stop new playback',
      (t) async {
    final h = Harness();
    final old = expectLater(
        h.session.play(baseUrl: 'http://local', text: 'old'),
        throwsA(isA<SpeechCancelled>()));
    await t.pump();
    h.sockets.single.done();
    await h.session.stop();
    await old;
    var finished = false;
    final next = h.session.play(baseUrl: 'http://local', text: 'new').then((_) {
      finished = true;
    });
    await t.pump();
    final starts = h.output.starts, stops = h.output.stops;
    h.output.drains.first.complete(true);
    await t.pump();
    expect(finished, false);
    expect(h.output.starts, starts);
    expect(h.output.stops, stops);
    h.sockets.last.audio();
    h.sockets.last.done();
    h.output.drains.last.complete(true);
    await next;
  });
  testWidgets(
      'stop failure rejects startup; explicit successful stop enables new request',
      (t) async {
    final h = Harness();
    h.output.fail = true;
    final failed = expectLater(
        h.session.play(baseUrl: 'http://local', text: 'old'),
        throwsA(isA<AudioShutdownFailure>()));
    await t.pump();
    await failed;
    expect(h.sockets, isEmpty);
    expect(h.session.shutdownConfirmed, false);
    h.output.fail = false;
    await h.session.stop();
    final next = h.session.play(baseUrl: 'http://local', text: 'new');
    await t.pump();
    h.sockets.single.done();
    h.output.drains.single.complete(true);
    await next;
  });
  testWidgets(
      'hung stop is bounded and late completion cannot resurrect retired startup',
      (t) async {
    final h = Harness();
    h.output.stopping = Completer<void>();
    final old = expectLater(
        h.session.play(baseUrl: 'http://local', text: 'old'),
        throwsA(isA<SpeechCancelled>()));
    final stop =
        expectLater(h.session.stop(), throwsA(isA<AudioShutdownFailure>()));
    await t.pump(const Duration(seconds: 4));
    await stop;
    await old;
    expect(h.session.shutdownConfirmed, false);
    expect(h.sockets, isEmpty);
    h.output.stopping!.complete();
    await t.pump();
    expect(h.session.shutdownConfirmed, true);
    expect(h.sockets, isEmpty);
  });
  testWidgets('same-turn play/stop never opens socket', (t) async {
    final h = Harness();
    final old = expectLater(
        h.session.play(baseUrl: 'http://local', text: 'old'),
        throwsA(isA<SpeechCancelled>()));
    await h.session.stop();
    await old;
    expect(h.sockets, isEmpty);
  });
  for (final hung in [false, true]) {
    testWidgets(
        'Mock $hung player-stop failure still cancels active TTS, retains protection',
        (t) async {
      final engine = f.FakeTts(), player = FailingPlayer();
      final gate = SpeechPriorityCoordinator(engine);
      final mock =
          MockScriptAudioService(audioPlayer: player, speechPriority: gate);
      final playing = mock.speakText('warning');
      await t.pump();
      if (hung) {
        player.stopping = Completer<void>();
      } else {
        player.fail = true;
      }
      final stopped =
          expectLater(mock.stop(), throwsA(isA<AudioShutdownFailure>()));
      await t.pump();
      expect(engine.stops, 1);
      if (hung) await t.pump(const Duration(seconds: 4));
      await stopped;
      await playing;
      expect(gate.priorityActive, true);
      final low =
          await gate.speakObservation(Object(), 'observation', () => true);
      expect(low, false);
      player.fail = false;
      if (hung) {
        player.stopping!.complete();
        await t.pump();
      }
      await mock.stop();
      expect(mock.shutdownConfirmed, true);
      expect(gate.priorityActive, false);
      await mock.dispose();
      gate.dispose();
    });
  }
  test(
      'generated player stop failure keeps lease; successful recovery releases it',
      () async {
    final gate = SpeechPriorityCoordinator(f.FakeTts()),
        player = FailingPlayer();
    final service = AudioHapticCueService(
        speechPriority: gate,
        audioPlayer: player,
        liveAudioPlayer: f.FakeLive());
    await service.playGeneratedSpeech(Uint8List.fromList([0]));
    expect(gate.priorityActive, true);
    player.fail = true;
    await expectLater(service.stopCue(), throwsA(isA<AudioShutdownFailure>()));
    expect(service.shutdownConfirmed, false);
    expect(gate.priorityActive, true);
    expect(await gate.speakObservation(Object(), 'low', () => true), false);
    player.fail = false;
    await service.stopCue();
    expect(gate.priorityActive, false);
    await service.dispose();
    gate.dispose();
  });
  test(
      'late native play after stop holds protection until second stop confirms',
      () async {
    final gate = SpeechPriorityCoordinator(f.FakeTts()),
        player = FailingPlayer();
    final service = AudioHapticCueService(
        speechPriority: gate,
        audioPlayer: player,
        liveAudioPlayer: f.FakeLive());
    player.starting = Completer<void>();
    final old = expectLater(
        service.playGeneratedSpeech(Uint8List.fromList([0])),
        throwsA(isA<SpeechCancelled>()));
    await Future<void>.delayed(Duration.zero);
    final stop =
        expectLater(service.stopCue(), throwsA(isA<AudioShutdownFailure>()));
    await Future<void>.delayed(const Duration(seconds: 4));
    await stop;
    expect(gate.priorityActive, true);
    player.starting!.complete();
    await Future<void>.delayed(Duration.zero);
    await old;
    final recovery = service.stopCue();
    await Future<void>.delayed(Duration.zero);
    await recovery;
    expect(service.shutdownConfirmed, true);
    expect(player.stops, greaterThanOrEqualTo(3));
    expect(gate.priorityActive, false);
    await service.dispose();
    gate.dispose();
  });
  test('uncertain shutdown is cancellation and never fallback speech',
      () async {
    final player = FailingPlayer()..fail = true;
    final gate = SpeechPriorityCoordinator(f.FakeTts());
    final service = AudioHapticCueService(
        speechPriority: gate,
        audioPlayer: player,
        liveAudioPlayer: f.FakeLive());
    var fallback = 0;
    await SpeechRequestScope().capture(() => true).run(
        () => service.playLiveGeneratedSpeech(
            baseUrl: 'http://local', text: 'old'), fallback: () async {
      fallback++;
    });
    expect(fallback, 0);
    expect(gate.priorityActive, true);
    player.fail = false;
    await service.stopCue();
    await service.dispose();
    gate.dispose();
  });
  test('real asset failure permits fallback only after confirmed output stop',
      () async {
    final engine = f.FakeTts(), player = FailingPlayer()..failPlay = true;
    final gate = SpeechPriorityCoordinator(engine);
    final mock =
        MockScriptAudioService(audioPlayer: player, speechPriority: gate);
    final playing = mock.playScript('mock_start');
    await Future<void>.delayed(Duration.zero);
    expect(player.starts, 1);
    expect(engine.spoken, hasLength(1));
    expect(mock.shutdownConfirmed, true);
    engine.finish();
    await playing;
    await mock.dispose();
    gate.dispose();
  });
}
