import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'package:mobi_passenger_app/src/pages/local_spatial_verification_page.dart';
import 'vision_observation_tts_test.dart' as f;

class Port implements NativeCuePort {
  final controller =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final calls = <String>[];
  Map<String, dynamic>? active;
  Completer<void>? stopGate, prepareGate;
  bool stopFailure = false;
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    calls.add(method);
    if (method == 'prepare') await prepareGate?.future;
    if (method == 'play') active = Map.of(args);
    if (method == 'stop') {
      await stopGate?.future;
      if (stopFailure) throw StateError('stop lost');
    }
    if ((method == 'stop' || method == 'dispose') &&
        active?['owner'] == args['owner']) {
      active = null;
    }
    return {'confirmed': true};
  }

  void finish({bool error = false}) {
    final run = active!;
    active = null;
    controller.add({
      ...run,
      'completed': !error,
      'error': error,
      'reason': error ? 'TIMEOUT' : 'MARKER'
    });
  }
}

class LocalTts extends FlutterTts {
  List<Map<String, String>> voices = [
    {'name': 'remote', 'locale': 'ko-KR', 'network_required': '1'},
    {'name': 'local', 'locale': 'ko-KR', 'network_required': '0'}
  ];
  Map<String, String>? chosen;
  int selection = 1;
  bool? lastFocus;
  @override
  Future<dynamic> get getVoices async => voices;
  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    chosen = voice;
    return selection;
  }

  @override
  Future<dynamic> setLanguage(String language) async {
    chosen = null; // Android may reset to a default voice when locale changes.
    return 1;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;
  @override
  Future<dynamic> setPitch(double pitch) async => 1;
  @override
  Future<dynamic> awaitSpeakCompletion(bool value) async => 1;
  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    lastFocus = focus;
    startHandler?.call();
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    scheduleMicrotask(() => cancelHandler?.call());
    return 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final direction in TestDirection.values) {
    test('native $direction passes exact direction and waits for marker',
        () async {
      final port = Port(), output = NativeDirectionalCueOutput(port: Port());
      await output.dispose();
      final actual = NativeDirectionalCueOutput(port: port);
      await actual.prepareFromGesture();
      final completed = actual.playCue(direction);
      await Future<void>.delayed(Duration.zero);
      expect(port.active!['direction'], direction.name.toUpperCase());
      port.finish();
      expect(await completed, isTrue);
      expect(actual.snapshot()['active'], isFalse);
      await actual.dispose();
    });
  }
  test('HRTF and unknown directions fail without starting native PCM',
      () async {
    final port = Port(), output = NativeDirectionalCueOutput(port: Port());
    await output.dispose();
    final actual = NativeDirectionalCueOutput(port: port);
    expect(() => actual.play('HRTF', 'LEFT'), throwsUnsupportedError);
    expect(() => actual.play('STEREO', 'UP'), throwsArgumentError);
    expect(port.calls, isEmpty);
    await actual.dispose();
  });
  test('duplicate start rejected; STOP retires old completion', () async {
    final port = Port(), output = NativeDirectionalCueOutput(port: Port());
    await output.dispose();
    final actual = NativeDirectionalCueOutput(port: port);
    await actual.prepareFromGesture();
    final first = actual.playCue(TestDirection.left);
    await Future<void>.delayed(Duration.zero);
    final old = Map<String, dynamic>.of(port.active!);
    await expectLater(actual.playCue(TestDirection.right), throwsStateError);
    await actual.stop();
    expect(await first, isFalse);
    final next = actual.playCue(TestDirection.right);
    await Future<void>.delayed(Duration.zero);
    port.controller.add({...old, 'completed': true});
    expect(actual.snapshot()['active'], isTrue);
    port.finish();
    expect(await next, isTrue);
    await actual.dispose();
  });
  test('unconfirmed stop blocks new output until original barrier completes',
      () async {
    final port = Port();
    final output = NativeDirectionalCueOutput(port: port);
    await output.prepareFromGesture();
    final cue = output.playCue(TestDirection.left);
    await Future<void>.delayed(Duration.zero);
    port.stopGate = Completer<void>();
    final stopping = output.stop();
    expect(await cue, isFalse);
    await expectLater(output.playCue(TestDirection.right), throwsStateError);
    port.stopGate!.complete();
    await stopping;
    final next = output.playCue(TestDirection.center);
    await Future<void>.delayed(Duration.zero);
    port.finish();
    expect(await next, isTrue);
    await output.dispose();
  });
  test('stop error is observable and keeps output blocked', () async {
    final port = Port();
    final output = NativeDirectionalCueOutput(port: port);
    await output.prepareFromGesture();
    port.stopFailure = true;
    await expectLater(output.stop(), throwsStateError);
    await expectLater(output.playCue(TestDirection.left), throwsStateError);
    await output.dispose();
  });
  test('dispose during prepare prevents late ready and is idempotent',
      () async {
    final port = Port()..prepareGate = Completer<void>();
    final output = NativeDirectionalCueOutput(port: port);
    final prepare = output.prepareFromGesture();
    final rejected = expectLater(prepare, throwsStateError);
    await output.dispose();
    await output.dispose();
    port.prepareGate!.complete();
    await rejected;
    expect(port.calls.where((c) => c == 'dispose').length, 1);
    expect(output.snapshot()['contextState'], 'closed',
        reason: port.calls.toString() + output.snapshot().toString());
  });
  test('old owner dispose/late event never stops the new owner', () async {
    final port = Port();
    final old = NativeDirectionalCueOutput(port: port);
    await old.prepareFromGesture();
    final first = old.playCue(TestDirection.left);
    await Future<void>.delayed(Duration.zero);
    final event = Map<String, dynamic>.of(port.active!);
    await old.stop();
    expect(await first, isFalse);
    final next = NativeDirectionalCueOutput(port: port);
    await next.prepareFromGesture();
    final second = next.playCue(TestDirection.right);
    await Future<void>.delayed(Duration.zero);
    await old.dispose();
    port.controller.add({...event, 'completed': true});
    expect(port.active, isNotNull);
    expect(next.snapshot()['active'], isTrue);
    port.finish();
    expect(await second, isTrue);
    await next.dispose();
  });
  test('native failure surfaces once and denies subsequent playback', () async {
    final port = Port();
    final output = NativeDirectionalCueOutput(port: port);
    await output.prepareFromGesture();
    final cue = output.playCue(TestDirection.left);
    final failed = expectLater(cue, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final event = Map<String, dynamic>.of(port.active!);
    port.finish(error: true);
    await failed;
    port.controller.add({...event, 'completed': true});
    await expectLater(output.playCue(TestDirection.center), throwsStateError);
    await output.dispose();
  });
  test('offline Korean selection excludes network voices', () async {
    final tts = LocalTts();
    final events = <String>[];
    final engine = FlutterSpeechEngine.platform(
        tts: tts,
        webPlatform: false,
        requireOfflineKoreanVoice: true,
        requestNativeFocus: true,
        diagnostic: events.add);
    await engine.prepare(requireKoreanVoice: true);
    expect(tts.chosen!['name'], 'local');
    expect(events, contains('TTS_READY'));
    final spoken = engine.speak('한국어 검증 문장');
    expect(tts.lastFocus, isTrue);
    tts.completionHandler!.call();
    await spoken;
    expect(events, contains('TTS_STARTED'));
    expect(events, contains('TTS_COMPLETED_CALLBACK'));
    final cancelled = engine.speak('중단 검증');
    final observed = expectLater(cancelled, throwsA(isA<SpeechCancelled>()));
    await engine.stop();
    await observed;
    expect(events, contains('TTS_STOP_CONFIRMED'));
  });
  test('priority preparation cannot bypass offline Korean selection', () async {
    final tts = LocalTts()
      ..voices = [
        {'name': 'remote', 'locale': 'ko-KR', 'network_required': '1'}
      ];
    final engine = FlutterSpeechEngine.platform(
        tts: tts, webPlatform: false, requireOfflineKoreanVoice: true);
    await expectLater(
        engine.prepare(requireKoreanVoice: false), throwsStateError);
  });
  for (final kind in [
    'missing',
    'network-only',
    'unknown-network',
    'bad-selection'
  ]) {
    test('Korean engine fails closed: $kind', () async {
      final tts = LocalTts();
      if (kind == 'missing') tts.voices = [];
      if (kind == 'network-only') {
        tts.voices = [
          {'name': 'online', 'locale': 'ko-KR', 'network_required': '1'}
        ];
      }
      if (kind == 'unknown-network') {
        tts.voices = [
          {'name': 'unknown', 'locale': 'ko-KR'}
        ];
      }
      if (kind == 'bad-selection') tts.selection = 0;
      final engine = FlutterSpeechEngine.platform(
          tts: tts, webPlatform: false, requireOfflineKoreanVoice: true);
      await expectLater(
          engine.prepare(requireKoreanVoice: true), throwsStateError);
    });
  }
  test('diagnostic exception cannot prevent native stop acknowledgement',
      () async {
    final engine = FlutterSpeechEngine.platform(
        tts: LocalTts(),
        webPlatform: false,
        diagnostic: (_) => throw StateError('trace'));
    await engine.stop();
  });
  for (final action in ['complete', 'stop', 'hold', 'background', 'dispose']) {
    testWidgets('native page $action preserves cue/TTS lifecycle', (t) async {
      t.view.physicalSize = const Size(1600, 2600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final port = Port(), tts = f.FakeTts();
      final output = NativeDirectionalCueOutput(port: port);
      await t.pumpWidget(MaterialApp(
          home: LocalSpatialVerificationPage(
              enabled: true,
              nativeStereoOnly: true,
              stopOnBackground: true,
              output: output,
              tts: tts,
              cuesFactory: (p) => AudioHapticCueService(
                  speechPriority: p,
                  audioPlayer: f.FakePlayer(),
                  liveAudioPlayer: f.FakeLive()))));
      expect(find.text('HRTF LEFT'), findsNothing);
      await t.tap(find.text('LEFT Cue → TTS'));
      await t.pump();
      expect(port.active, isNotNull);
      expect(tts.spoken, isEmpty);
      if (action == 'complete') {
        port.finish();
        await t.pump();
        expect(tts.spoken.length, 1);
        await t.pump(const Duration(seconds: 4));
        expect(tts.playing!.isCompleted, isFalse);
        tts.finish();
        await t.pump();
      }
      if (action == 'stop') {
        await t.tap(find.text('STOP'));
        await t.pump();
        expect(tts.spoken, isEmpty);
      }
      if (action == 'hold') {
        await t.tap(find.text('Live Hold 선점'));
        await t.pump();
        expect(port.active, isNull);
        expect(tts.spoken.single, contains('Live Hold'));
        tts.finish();
        await t.pump();
      }
      if (action == 'background') {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await t.pump();
        expect(port.active, isNull);
        expect(tts.spoken, isEmpty);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pump();
        expect(tts.spoken, isEmpty);
      }
      await t.pumpWidget(const SizedBox());
      // Drain page-owned asynchronous shutdown, not an independently invoked dispose.
      for (var i = 0; i < 10; i++) {
        await t.pump();
      }
      expect(output.snapshot()['contextState'], 'closed',
          reason: port.calls.toString() + output.snapshot().toString());
      expect(port.active, isNull);
      expect(t.takeException(), isNull);
    });
  }
}
