import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'package:mobi_passenger_app/src/services/vision_observation_speech.dart';
import 'vision_observation_tts_test.dart' as fixtures;

class Feedback implements CueFeedback {
  int beeps = 0, vibrations = 0;
  bool fail = false;
  Completer<void>? delayed;
  @override
  Future<void> beep() async {
    beeps++;
    if (fail) throw StateError('device error');
    await delayed?.future;
  }

  @override
  Future<void> vibrate({required bool heavy}) async {
    vibrations++;
  }
}

class Engine extends fixtures.FakeTts {
  bool throwSpeak = false;
  @override
  Future<void> speak(String text) {
    if (throwSpeak) throw StateError('TTS failure');
    return super.speak(text);
  }
}

class StalledStop extends Engine {
  @override
  Future<void> stop() => Completer<void>().future;
}

class BufferedLive extends fixtures.FakeLive {
  final done = Completer<void>();
  bool started = false;
  @override
  Future<void> play(
          {required String baseUrl,
          required String text,
          void Function()? onFirstAudio}) =>
      markStarted();
  Future<void> markStarted() {
    started = true;
    return done.future;
  }

  @override
  Future<void> stop() async {
    if (started && !done.isCompleted) done.complete();
  }
}

const danger = V3Cue(
    type: 'DANGER',
    ttsMode: 'SAFETY_LOCAL',
    shouldBeep: true,
    shouldVibrate: true,
    message: '위험 구역입니다.');

void main() {
  const channel = MethodChannel('flutter_tts');
  Object? reply;
  bool throwRequest = false;
  int nativeStops = 0;
  late FlutterTts tts;
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    reply = null;
    throwRequest = false;
    nativeStops = 0;
    fixtures.fixtureFrames.clear();
    tts = FlutterTts();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getVoices') {
        return [
          {'locale': 'ko-KR', 'name': 'Korean'}
        ];
      }
      if (call.method == 'speak') {
        if (throwRequest) throw PlatformException(code: 'engine-failure');
        return reply;
      }
      if (call.method == 'stop') nativeStops++;
      return 1;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  FlutterSpeechEngine webEngine() => FlutterSpeechEngine.platform(
      tts: tts,
      webPlatform: true,
      browserActive: () => false,
      browserCancel: () {});

  testWidgets('Web null is request acceptance, not failure or completion',
      (t) async {
    final engine = webEngine();
    await engine.prepare(requireKoreanVoice: true);
    bool ended = false;
    final playing = engine.speak('녹화 영상에서 버스가 감지되었습니다.').then((_) {
      ended = true;
    });
    await t.pump();
    expect(ended, isFalse);
    expect(nativeStops, 0);
    await tts.platformCallHandler(const MethodCall('speak.onStart'));
    await t.pump();
    expect(ended, isFalse);
    await tts.platformCallHandler(const MethodCall('speak.onComplete'));
    await playing;
    expect(ended, isTrue);
  });

  testWidgets('Android 1 waits for completion; null and zero are failures',
      (t) async {
    final engine = FlutterSpeechEngine.platform(tts: tts, webPlatform: false);
    reply = 1;
    bool ended = false;
    final playing = engine.speak('위험 안내').then((_) {
      ended = true;
    });
    await t.pump();
    expect(ended, isFalse);
    await tts.platformCallHandler(const MethodCall('speak.onComplete'));
    await playing;
    for (final result in [null, 0]) {
      reply = result;
      final failed = expectLater(engine.speak('위험 안내'), throwsStateError);
      await t.pump();
      await failed;
    }
  });

  testWidgets('platform exceptions, error and external cancel remain failures',
      (t) async {
    final engine = webEngine();
    throwRequest = true;
    final failed =
        expectLater(engine.speak('버스'), throwsA(isA<PlatformException>()));
    await t.pump();
    await failed;
    throwRequest = false;
    for (final event in ['speak.onError', 'speak.onCancel']) {
      final result = expectLater(engine.speak('버스'), throwsStateError);
      await t.pump();
      await tts.platformCallHandler(MethodCall(event, 'error'));
      await result;
    }
  });

  testWidgets(
      'shared real adapter: low stop cannot cancel current safety speech',
      (t) async {
    final gate = SpeechPriorityCoordinator(webEngine());
    final lowOwner = Object(), highOwner = Object();
    final low = gate.speakObservation(lowOwner, '관찰', () => true);
    await t.pump();
    final lease = await gate.acquirePriority();
    await t.pump();
    await low;
    final safety = gate.speakPriority(highOwner, '위험 안내', () => true);
    await t.pump();
    final stops = nativeStops;
    await gate.stopObservation(lowOwner);
    await t.pump();
    expect(nativeStops, stops);
    await tts.platformCallHandler(const MethodCall('speak.onComplete'));
    await t.pump();
    await safety;
    lease.release();
    gate.dispose();
  });

  testWidgets(
      'native cancel acknowledgement gates reuse; stale callback has no new owner',
      (t) async {
    reply = 1;
    final engine = FlutterSpeechEngine.platform(tts: tts, webPlatform: false);
    final gate = SpeechPriorityCoordinator(engine);
    final low = gate.speakObservation(Object(), '관찰', () => true);
    await t.pump();
    final acquiring = gate.acquirePriority();
    bool highStarted = false;
    final high = gate.speakPriority(Object(), '위험 안내', () {
      highStarted = true;
      return true;
    });
    await t.pump();
    expect(highStarted, isFalse);
    await tts.platformCallHandler(const MethodCall('speak.onCancel'));
    await t.pump();
    await low;
    final lease = await acquiring;
    expect(highStarted, isTrue);
    await tts.platformCallHandler(const MethodCall('speak.onComplete'));
    await t.pump();
    await high;
    lease.release();
    gate.dispose();
  });

  testWidgets('missing native cancellation quarantines engine, no unsafe reuse',
      (t) async {
    reply = 1;
    final engine = FlutterSpeechEngine.platform(tts: tts, webPlatform: false);
    final playing = expectLater(engine.speak('관찰'), throwsStateError);
    await t.pump();
    final stopped =
        expectLater(engine.stop(), throwsA(isA<TimeoutException>()));
    await t.pump(const Duration(seconds: 3));
    await playing;
    await stopped;
    await expectLater(
        engine.prepare(requireKoreanVoice: false), throwsStateError);
    // A late retirement callback cannot complete a subsequently created run.
    await tts.platformCallHandler(const MethodCall('speak.onCancel'));
  });

  testWidgets(
      'warning starts and repeats before uncompleted TTS, duplicate danger has one timer',
      (t) async {
    final engine = Engine(), feedback = Feedback();
    final gate = SpeechPriorityCoordinator(engine);
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    await service.playCue(danger);
    await t.pump();
    expect(engine.spoken, ['위험 구역입니다.']);
    expect(engine.playing!.isCompleted, isFalse);
    expect(feedback.beeps, 1);
    expect(service.isLooping, isTrue);
    await service.playCue(danger);
    await t.pump(const Duration(milliseconds: 900));
    expect(feedback.beeps, 2);
    expect(engine.spoken.length, 1);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([fixtures.observation()], Duration.zero);
    await t.pump();
    speech.clear();
    await t.pump();
    expect(engine.spoken.length, 1);
    expect(engine.playing!.isCompleted, isFalse);
    await service.stopCue();
    final count = feedback.beeps;
    await t.pump(const Duration(seconds: 3));
    expect(feedback.beeps, count);
    expect(gate.priorityActive, isFalse);
    speech.dispose();
    await service.dispose();
    gate.dispose();
  });

  testWidgets('TTS exception does not suppress alerts or escape into ride flow',
      (t) async {
    final engine = Engine()..throwSpeak = true;
    final gate = SpeechPriorityCoordinator(engine), feedback = Feedback();
    final errors = <String>[];
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        onAudioError: errors.add,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    await service.playCue(danger);
    await t.pump();
    expect(service.speechError, isNotNull);
    expect(errors, isNotEmpty);
    await t.pump(const Duration(milliseconds: 900));
    expect(feedback.beeps, 2);
    await service.dispose();
    gate.dispose();
  });

  testWidgets(
      'warning output failure is explicit and repeated slow output never overlaps',
      (t) async {
    final gate = SpeechPriorityCoordinator(Engine()),
        feedback = Feedback()..delayed = Completer();
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    final start = service.playCue(danger, speakMessage: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 900));
    expect(feedback.beeps, 1);
    await t.pump(const Duration(milliseconds: 200));
    await start;
    expect(service.warningError, isNotNull);
    await t.pump(const Duration(seconds: 3));
    expect(
        feedback.beeps, 1); // timeout must not queue overlapping native calls
    await service.stopCue();
    feedback.delayed!.complete();
    await t.pump();
    final count = feedback.beeps;
    await t.pump(const Duration(seconds: 2));
    expect(feedback.beeps, count);
    await service.dispose();
    gate.dispose();
  });

  testWidgets(
      'buffered live playback retains priority until drain or explicit stop',
      (t) async {
    final engine = Engine();
    final gate = SpeechPriorityCoordinator(engine);
    final live = BufferedLive();
    final service = AudioHapticCueService(
        speechPriority: gate,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: live);
    final playing = service.playLiveGeneratedSpeech(
        baseUrl: 'http://localhost', text: '안내');
    await t.pump();
    expect(gate.priorityActive, isTrue);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([fixtures.observation()], Duration.zero);
    await t.pump();
    expect(engine.spoken, isEmpty);
    speech.clear();
    await t.pump();
    expect(gate.priorityActive, isTrue);
    live.done.complete();
    await t.pump();
    await playing;
    expect(gate.priorityActive, isFalse);
    speech.dispose();
    await service.dispose();
    gate.dispose();
  });

  testWidgets(
      'multi-camera summary is order independent and preserves Replay/Live separation',
      (t) async {
    final engine = Engine(), gate = SpeechPriorityCoordinator(Engine());
    final own = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(own, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    final bus = fixtures.observation(classes: ['bus'])..['cameraId'] = 'a';
    final door = fixtures.observation(event: 'door', classes: ['bus_door'])
      ..['cameraId'] = 'z';
    final live = fixtures
        .observation(event: 'live', source: 'live', classes: ['bus'])
      ..['cameraId'] = 'live';
    speech.update([door, live, bus], Duration.zero);
    await t.pump();
    expect(engine.spoken.single,
        '버스가 감지되었습니다. 여러 카메라의 녹화 영상 관찰에서 버스와 버스 문이 감지되었습니다.');
    engine.finish();
    await t.pump();
    speech.update([bus, door, live], Duration.zero);
    await t.pump();
    expect(engine.spoken.length, 1);
    expect(engine.spoken.single, isNot(contains('목표')));
    speech.dispose();
    await t.pump();
    own.dispose();
    gate.dispose();
  });

  testWidgets(
      'multi-camera expiry and invalid scope do not retain partial stale summary',
      (t) async {
    final engine = Engine(), own = SpeechPriorityCoordinator(Engine());
    final gate = SpeechPriorityCoordinator(engine);
    var clock = 0;
    final speech = VisionObservationSpeech(gate, nowMicros: () => clock)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([
      fixtures.observation(classes: ['bus'], ttl: 1)..['cameraId'] = 'a',
      fixtures.observation(event: 'door', classes: ['bus_door'], ttl: 3)
        ..['cameraId'] = 'z',
      fixtures.observation(event: 'foreign', session: 'foreign', source: 'live')
    ], Duration.zero);
    await t.pump();
    expect(engine.spoken.single.startsWith('여러 카메라의 녹화 영상'), isTrue);
    clock = 1100000;
    speech.tick();
    await t.pump();
    expect(engine.stops, 1);
    speech.dispose();
    await t.pump();
    gate.dispose();
    own.dispose();
  });
  testWidgets(
      'Web explicit zero is failure, successful null never auto-finishes',
      (t) async {
    final engine = webEngine();
    reply = 0;
    final failed = expectLater(engine.speak('버스'), throwsStateError);
    await t.pump();
    await failed;
  });

  testWidgets('generated audio and changed danger do not retire warning timer',
      (t) async {
    final engine = Engine(), feedback = Feedback();
    final gate = SpeechPriorityCoordinator(engine),
        player = fixtures.FakePlayer();
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        audioPlayer: player,
        liveAudioPlayer: fixtures.FakeLive());
    await service.playCue(danger, speakMessage: false);
    await service.playGeneratedSpeech(Uint8List.fromList([0]));
    await t.pump(const Duration(milliseconds: 900));
    expect(feedback.beeps, 2);
    player.completion.add(null);
    await t.pump();
    expect(gate.priorityActive, isTrue);
    await service.playCue(
        const V3Cue(
            type: 'WRONG_BUS_NEAR',
            ttsMode: 'SAFETY_LOCAL',
            shouldVibrate: false,
            shouldBeep: true),
        speakMessage: false);
    await t.pump(const Duration(milliseconds: 900));
    expect(feedback.beeps, 4); // new immediate pulse + one new timer
    await service.stopCue();
    final before = feedback.beeps;
    await t.pump(const Duration(seconds: 3));
    expect(feedback.beeps, before);
    await service.dispose();
    gate.dispose();
  });

  testWidgets('missing buffered completion keeps priority until explicit stop',
      (t) async {
    final gate = SpeechPriorityCoordinator(Engine()), live = BufferedLive();
    final service = AudioHapticCueService(
        speechPriority: gate,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: live);
    final playing = expectLater(
        service.playLiveGeneratedSpeech(
            baseUrl: 'http://localhost', text: '안내'),
        throwsA(isA<SpeechCancelled>()));
    await t.pump(const Duration(seconds: 2));
    expect(gate.priorityActive, isTrue);
    await service.stopCue();
    await playing;
    expect(gate.priorityActive, isFalse);
    await service.dispose();
    gate.dispose();
  });

  testWidgets(
      'stalled low-priority stop cannot block independent warning outputs',
      (t) async {
    final engine = StalledStop(), feedback = Feedback();
    final gate = SpeechPriorityCoordinator(engine);
    final low = gate.speakObservation(Object(), '관찰', () => true);
    await t.pump();
    final service = AudioHapticCueService(
        speechPriority: gate,
        feedback: feedback,
        audioPlayer: fixtures.FakePlayer(),
        liveAudioPlayer: fixtures.FakeLive());
    await service.playCue(danger);
    await t.pump();
    expect(feedback.beeps, 1);
    await t.pump(const Duration(seconds: 4));
    await t.pump();
    expect(feedback.beeps, greaterThan(1));
    expect(
        engine.spoken, ['관찰']); // uncertain cancellation forbids engine reuse
    await low;
    await service.dispose();
    gate.dispose();
  });
}
