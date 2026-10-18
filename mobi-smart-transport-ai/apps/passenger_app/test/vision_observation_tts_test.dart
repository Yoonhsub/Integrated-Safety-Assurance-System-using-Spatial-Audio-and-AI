import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/mock_scenario/mock_scenario_controller.dart';
import 'package:mobi_passenger_app/src/services/audio_shutdown.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/vision_observation_speech.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'package:mobi_passenger_app/src/services/live_audio_player.dart';
import 'package:mobi_passenger_app/src/services/mock_script_audio_service.dart';
import 'package:mobi_passenger_app/src/widgets/vision_observation_panel.dart';

class FakeTts implements SpeechEngine {
  final List<String> spoken = [];
  int stops = 0;
  Completer<void>? preparing, playing;
  bool fail = false;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {
    if (fail && requireKoreanVoice) throw StateError('no engine');
    await preparing?.future;
  }

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    playing = Completer();
    return playing!.future;
  }

  void finish() {
    if (playing?.isCompleted == false) playing!.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    finish();
  }
}

class FakePlayer implements AudioPlayer {
  final completion = StreamController<void>.broadcast();
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    unawaited(completion.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #onPlayerComplete) return completion.stream;
    if (invocation.memberName == #play) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }
}

class FakeLive implements LiveAudioPlayer {
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final Map<String, int> fixtureFrames = {};
Map<String, dynamic> observation(
        {String event = 'e',
        String session = 's',
        List<String> classes = const ['bus', 'bus_door'],
        double ttl = 3,
        String source = 'replay'}) =>
    {
      'sessionId': session,
      'cameraId': 'camera',
      'cameraEpoch': 'epoch',
      'visionEventId': event,
      'frameIndex':
          fixtureFrames.putIfAbsent(event, () => fixtureFrames.length),
      'state': 'available',
      'inferenceStatus': 'ok',
      'sourceType': source,
      'validForSeconds': ttl,
      'observedClasses': classes,
      'receivedAt': 'test',
    };
void main() {
  setUp(fixtureFrames.clear);
  testWidgets('V3 scenario boundary updates without parent rebuild and repeats',
      (t) async {
    final controller = MockScenarioController();
    final gate = SpeechPriorityCoordinator(FakeTts());
    var parentBuilds = 0;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      parentBuilds++;
      return Scaffold(
          body: ScenarioObservationBuilder(
        controller: controller,
        builder: (context, playing) => VisionObservationPanel(
          sessionId: 's',
          ownerUid: 'alice',
          priorityBlocked: playing,
          speechPriority: gate,
          fetch: (_) async => {'sessionId': 's', 'observations': []},
        ),
      ));
    })));
    await t.pump();
    final baseline = parentBuilds;
    for (var i = 0; i < 3; i++) {
      controller.play();
      await t.pump();
      await t.pump();
      expect(
          t
              .widget<VisionObservationPanel>(
                  find.byType(VisionObservationPanel))
              .priorityBlocked,
          isTrue);
      expect(gate.priorityActive, isTrue);
      if (i == 1) {
        controller.reset();
      } else {
        controller.pause();
      }
      await t.pump();
      await t.pump();
      expect(
          t
              .widget<VisionObservationPanel>(
                  find.byType(VisionObservationPanel))
              .priorityBlocked,
          isFalse);
      expect(gate.priorityActive, isFalse);
      expect(parentBuilds, baseline);
    }
    controller.play();
    await t.pump();
    await t.pump();
    await t.pumpWidget(const SizedBox());
    controller.pause();
    controller.play();
    controller.pause();
    await t.pump();
    expect(gate.priorityActive, isFalse);
    expect(t.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('V3 scenario ending cannot release unconfirmed audio protection',
      (t) async {
    final controller = MockScenarioController();
    final gate = SpeechPriorityCoordinator(FakeTts());
    PriorityLease? safety;
    final shutdown = AudioShutdown(
        onHold: () => safety ??= gate.claimPriority(),
        onConfirmed: () {
          safety?.release();
          safety = null;
        });
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ScenarioObservationBuilder(
      controller: controller,
      builder: (context, playing) => VisionObservationPanel(
        sessionId: 's',
        ownerUid: 'alice',
        priorityBlocked: playing,
        speechPriority: gate,
        fetch: (_) async => {'sessionId': 's', 'observations': []},
      ),
    ))));
    controller.play();
    await t.pump();
    await t.pump();
    await expectLater(
        shutdown.run([
          () async {
            throw StateError('stop failed');
          }
        ]),
        throwsA(isA<AudioShutdownFailure>()));
    controller.pause();
    await t.pump();
    await t.pump();
    expect(
        t
            .widget<VisionObservationPanel>(find.byType(VisionObservationPanel))
            .priorityBlocked,
        isFalse);
    expect(shutdown.confirmed, isFalse);
    expect(gate.priorityActive, isTrue);
    // Only the output owner may confirm shutdown and release its own lease.
    await shutdown.run([() async {}]);
    await t.pump();
    expect(gate.priorityActive, isFalse);
    await t.pumpWidget(const SizedBox());
    controller.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'V3 latest observation after pause speaks once and expired replay stays silent',
      (t) async {
    final controller = MockScenarioController();
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    var now = 0;
    var items = [observation(event: 'initial', ttl: 30)];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ScenarioObservationBuilder(
      controller: controller,
      builder: (context, playing) => VisionObservationPanel(
        sessionId: 's',
        ownerUid: 'alice',
        priorityBlocked: playing,
        speechPriority: gate,
        speechClock: () => now,
        fetch: (_) async => {'sessionId': 's', 'observations': items},
      ),
    ))));
    await t.pump();
    controller.play();
    await t.pump();
    await t.pump();
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    expect(engine.spoken, isEmpty);
    controller.pause();
    await t.pump();
    await t.pump();
    items = [
      observation(event: 'new', classes: ['bus'], ttl: 30)
    ];
    now = 1000000;
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(engine.spoken, hasLength(1));
    expect(engine.spoken.single, contains('녹화 영상'));
    engine.finish();
    await t.pump();
    await t.pump();
    now = 10000000;
    items = [
      observation(event: 'same-meaning', classes: ['bus'], ttl: 30)
    ];
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(engine.spoken, hasLength(1));
    items = [
      observation(event: 'expired', classes: ['bus_door'], ttl: 0)
    ];
    now = 20000000;
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(engine.spoken, hasLength(1));
    await t.pumpWidget(const SizedBox());
    controller.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets('V3 natural scenario completion updates Observation subscription',
      (t) async {
    final controller = MockScenarioController()
      ..selectScenario('s07_danger_zone')
      ..setPlaybackSpeed(2);
    final gate = SpeechPriorityCoordinator(FakeTts());
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ScenarioObservationBuilder(
      controller: controller,
      builder: (context, playing) => VisionObservationPanel(
        sessionId: 's',
        ownerUid: 'alice',
        priorityBlocked: playing,
        speechPriority: gate,
        fetch: (_) async => {'sessionId': 's', 'observations': []},
      ),
    ))));
    // Controller uses DateTime.now: use its real timer, not fictitious pump time.
    await t.runAsync(() async {
      controller.play();
    });
    await t.pump();
    await t.pump();
    expect(gate.priorityActive, isTrue);
    await t.runAsync(() async {
      await Future<void>.delayed(controller.selectedScenario.duration ~/ 2 +
          const Duration(milliseconds: 300));
    });
    expect(controller.state.isPlaying, isFalse);
    await t.pump();
    await t.pump();
    expect(gate.priorityActive, isFalse);
    expect(
        t
            .widget<VisionObservationPanel>(find.byType(VisionObservationPanel))
            .priorityBlocked,
        isFalse);
    await t.pumpWidget(const SizedBox());
    controller.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'OFF default, explicit ON uses only fixed Korean Replay observation',
      (t) async {
    final engine = FakeTts(), gate = SpeechPriorityCoordinator(FakeTts());
    final own = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(own, nowMicros: () => 0)
      ..setScope('alice', 's', 0);
    speech.update([observation()], Duration.zero);
    await t.pump();
    expect(engine.spoken, isEmpty);
    speech.setEnabled(true);
    await t.pump();
    expect(engine.spoken, ['녹화 영상에서 버스와 버스 문이 감지되었습니다.']);
    expect(engine.spoken.join(), isNot(contains('승차')));
    speech.dispose();
    await t.pump();
    own.dispose();
    gate.dispose();
  });
  testWidgets('same receipt and later same meaning do not repeat', (t) async {
    final engine = FakeTts(), gate = SpeechPriorityCoordinator(FakeTts());
    final own = SpeechPriorityCoordinator(engine);
    var clock = 0;
    final speech = VisionObservationSpeech(own, nowMicros: () => clock)
      ..setScope('alice', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    engine.finish();
    await t.pump();
    for (var i = 0; i < 10; i++) {
      clock += 1000000;
      speech
          .update([observation(event: i.isEven ? 'e' : 'e$i')], Duration.zero);
      await t.pump();
    }
    expect(engine.spoken.length, 1);
    speech.dispose();
    await t.pump();
    own.dispose();
    gate.dispose();
  });
  testWidgets(
      'latest changed meaning only, bounded cooldown discards stale pending',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    var clock = 0;
    final speech = VisionObservationSpeech(gate, nowMicros: () => clock)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([
      observation(classes: ['bus'])
    ], Duration.zero);
    await t.pump();
    engine.finish();
    await t.pump();
    clock = 1000000;
    speech.update([
      observation(event: 'door', classes: ['bus_door'])
    ], Duration.zero);
    await t.pump();
    clock = 9000000;
    speech.tick();
    await t.pump();
    expect(engine.spoken.length, 1);
    speech.update([observation(event: 'both')], Duration.zero);
    await t.pump();
    expect(engine.spoken.last, '녹화 영상에서 버스와 버스 문이 감지되었습니다.');
    expect(engine.spoken.length, 2);
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'repeat polling cannot extend receipt TTL or let expired speech continue',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    var clock = 0;
    final speech = VisionObservationSpeech(gate, nowMicros: () => clock)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    clock = 2000000;
    speech.update([observation()], Duration.zero);
    clock = 3100000;
    speech.tick();
    await t.pump();
    expect(engine.stops, 1);
    expect(speech.speaking, isFalse);
    speech.update([observation()], Duration.zero);
    await t.pump();
    expect(engine.spoken.length, 1);
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets('request latency and malformed scope/classes/source fail closed',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], const Duration(seconds: 4));
    speech.update([
      observation(session: 'other'),
      observation(source: 'unknown'),
      observation(classes: ['person'])
    ], Duration.zero);
    await t.pump();
    expect(engine.spoken, isEmpty);
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'OFF and explicit stop clear work without immediate same-object replay',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    speech.stop();
    await t.pump();
    speech.update([observation(event: 'new')], Duration.zero);
    await t.pump();
    expect(engine.spoken.length, 1);
    speech.setEnabled(false);
    speech.update([
      observation(event: 'third', classes: ['bus'])
    ], Duration.zero);
    await t.pump();
    expect(engine.spoken.length, 1);
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets('scope reset invalidates delayed prepare before native start',
      (t) async {
    final engine = FakeTts()..preparing = Completer();
    final gate = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    speech.setScope('a', 's', 1);
    engine.preparing!.complete();
    await t.pump();
    expect(engine.spoken, isEmpty);
    expect(speech.enabled, isFalse);
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'priority preempts Observation; later observation stop cannot cancel safety',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    final lease = await gate.acquirePriority();
    await t.pump();
    final safety = gate.speakPriority(Object(), '위험 안내', () => true);
    await t.pump();
    expect(engine.spoken.last, '위험 안내');
    final stops = engine.stops;
    speech.clear();
    speech.setEnabled(false);
    await t.pump();
    expect(engine.stops, stops);
    engine.finish();
    await t.pump();
    await safety;
    lease.release();
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'priority arriving during prepare blocks stale native Observation start',
      (t) async {
    final engine = FakeTts()..preparing = Completer();
    final gate = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    final leaseFuture = gate.acquirePriority();
    engine.preparing!.complete();
    await t.pump();
    final lease = await leaseFuture;
    expect(engine.spoken, isEmpty);
    lease.release();
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'Observation engine failure is local and priority cue still works',
      (t) async {
    final engine = FakeTts()..fail = true;
    final gate = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    expect(speech.error, isNotNull);
    expect(speech.enabled, isFalse);
    final lease = await gate.acquirePriority();
    final high = gate.speakPriority(Object(), '안전 안내', () => true);
    await t.pump();
    expect(engine.spoken, ['안전 안내']);
    engine.finish();
    await t.pump();
    await high;
    lease.release();
    speech.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'AudioHapticCueService existing local warning obtains priority lease',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final service = AudioHapticCueService(
        speechPriority: gate,
        audioPlayer: FakePlayer(),
        liveAudioPlayer: FakeLive());
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    final high = service.speakLocal('위험 구역입니다.');
    await t.pump();
    expect(gate.priorityActive, isTrue);
    expect(engine.spoken.last, '위험 구역입니다.');
    speech.clear();
    await t.pump();
    expect(engine.playing!.isCompleted, isFalse);
    await service.stopCue();
    await high;
    expect(gate.priorityActive, isFalse);
    speech.dispose();
    await service.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets('widget empty/unbound response cancels voice and OFF keeps text',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    var empty = false;
    await t.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's',
            ownerUid: 'a',
            speechPriority: gate,
            speechClock: () => t.binding.clock.now().microsecondsSinceEpoch,
            fetch: (_) async => {
                  'sessionId': 's',
                  'observations': empty ? [] : [observation()]
                })));
    await t.pump();
    expect(engine.spoken, isEmpty);
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    expect(engine.spoken.length, 1);
    empty = true;
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(engine.stops, 1);
    expect(find.text('현재 관찰 정보가 없습니다'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    gate.dispose();
  });
  testWidgets('late previous-session response never speaks in new session',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final old = Completer<Map<String, dynamic>>();
    Widget panel(String sid) => MaterialApp(
        home: VisionObservationPanel(
            sessionId: sid,
            ownerUid: 'a',
            speechPriority: gate,
            fetch: (_) => sid == 's'
                ? old.future
                : Future.value({'sessionId': sid, 'observations': []})));
    await t.pumpWidget(panel('s'));
    await t.pump();
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    await t.pumpWidget(panel('new'));
    old.complete({
      'sessionId': 's',
      'observations': [observation()]
    });
    await t.pump();
    expect(engine.spoken, isEmpty);
    expect(find.text('Vision 음성 OFF'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    gate.dispose();
  });
  testWidgets('logout cancels speech and blocks late HTTP response', (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final changes = StreamController<String?>();
    await t.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's',
            ownerUid: 'a',
            authChanges: changes.stream,
            speechPriority: gate,
            fetch: (_) async => {
                  'sessionId': 's',
                  'observations': [observation()]
                })));
    await t.pump();
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    changes.add(null);
    await t.pump();
    expect(engine.stops, 1);
    expect(engine.spoken.length, 1);
    await t.pump(const Duration(seconds: 2));
    expect(engine.spoken.length, 1);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    unawaited(changes.close());
    gate.dispose();
  });
  testWidgets(
      'legacy script TTS also blocks Observation and keeps owner cancellation',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final mock =
        MockScriptAudioService(audioPlayer: FakePlayer(), speechPriority: gate);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    final high = mock.speakText('기존 시나리오 안내');
    await t.pump();
    expect(engine.spoken.last, '기존 시나리오 안내');
    final stops = engine.stops;
    speech.stop();
    await t.pump();
    expect(engine.stops, stops);
    await mock.stop();
    await high;
    expect(gate.priorityActive, isFalse);
    speech.dispose();
    await mock.dispose();
    await t.pump();
    gate.dispose();
  });
  testWidgets(
      'scenario block lease and disposal do not leak or queue prior observation',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    Widget panel(bool blocked) => MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's',
            ownerUid: 'a',
            speechPriority: gate,
            priorityBlocked: blocked,
            fetch: (_) async => {
                  'sessionId': 's',
                  'observations': [observation()]
                }));
    await t.pumpWidget(panel(true));
    await t.pump();
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    expect(gate.priorityActive, isTrue);
    expect(engine.spoken, isEmpty);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    expect(gate.priorityActive, isFalse);
    gate.dispose();
  });
  testWidgets(
      'disposing while speech engine preparation is delayed prevents late voice',
      (t) async {
    final engine = FakeTts()..preparing = Completer();
    final gate = SpeechPriorityCoordinator(engine);
    final speech = VisionObservationSpeech(gate, nowMicros: () => 0)
      ..setScope('a', 's', 0)
      ..setEnabled(true);
    speech.update([observation()], Duration.zero);
    await t.pump();
    speech.dispose();
    engine.preparing!.complete();
    await t.pump();
    expect(engine.spoken, isEmpty);
    gate.dispose();
  });
  testWidgets(
      'scope version reset with same session cancels voice and resets ON',
      (t) async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    Widget panel(int version) => MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's',
            ownerUid: 'a',
            scopeVersion: version,
            speechPriority: gate,
            fetch: (_) async => {
                  'sessionId': 's',
                  'observations': [observation()]
                }));
    await t.pumpWidget(panel(0));
    await t.pump();
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    await t.pumpWidget(panel(1));
    await t.pump();
    expect(engine.stops, 1);
    expect(find.text('Vision 음성 OFF'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    gate.dispose();
  });
  test('generated audio completion cannot release a continuing danger cue',
      () async {
    final engine = FakeTts();
    final gate = SpeechPriorityCoordinator(engine);
    final player = FakePlayer();
    final service = AudioHapticCueService(
        speechPriority: gate, audioPlayer: player, liveAudioPlayer: FakeLive());
    await service.playCue(
        const V3Cue(
            type: 'DANGER',
            ttsMode: 'SAFETY_LOCAL',
            shouldVibrate: false,
            shouldBeep: false),
        speakMessage: false,
        systemBeep: false);
    expect(gate.priorityActive, isTrue);
    await service.playGeneratedSpeech(Uint8List.fromList([0]));
    player.completion.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(gate.priorityActive, isTrue);
    expect(service.activeCueType, 'DANGER');
    await service.stopCue();
    expect(gate.priorityActive, isFalse);
    await service.dispose();
    await Future<void>.delayed(Duration.zero);
    gate.dispose();
  });
}
