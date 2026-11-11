import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';
import 'package:mobi_passenger_app/src/local_vision/frame_pump.dart';
import 'package:mobi_passenger_app/src/services/vision_screen_audio.dart';
import 'package:mobi_passenger_app/src/services/head_tracking_direction.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/widgets/vision_screen_audio_panel.dart';
import 'local_vision_test.dart' as camera;
import 'native_android_audio_test.dart' as native;
import 'vision_observation_tts_test.dart' as speech;

class _HeadPort implements HeadTrackedCuePort {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    calls.add(method);
    return method == 'start'
        ? {'running': true, 'spatial': true}
        : {'confirmed': true, 'running': false};
  }
}

// All detections below are explicit fixtures; no real model/device claim.
LocalObservation detection(int ticks,
        {double x = .05, double confidence = .9, List<LocalBox>? boxes}) =>
    LocalObservation(camera.frame(ticks), Uint8List(0),
        boxes ?? [LocalBox('bus', confidence, x, .2, .2, .3)], 2, 2, 1, 2);
void main() {
  Future<void> flush(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.pump();
    }
  }

  for (final side in ['LEFT', 'CENTER', 'RIGHT']) {
    testWidgets(
        'DetectionResult fixture $side to existing Native Cue then actual text TTS contract',
        (t) async {
      final port = native.Port(), tts = speech.FakeTts();
      final output = NativeDirectionalCueOutput(port: port);
      final realEngine = SpatialVerificationEngine(output, tts,
          allowDirectTestCommands: false);
      final priority = SpeechPriorityCoordinator(realEngine);
      var now = 0;
      final a = VisionScreenAudio(
          priority: priority,
          engine: realEngine,
          sessionGeneration: 's:1',
          isCurrent: () => true,
          nowMicros: () => now);
      a.setEnabled(true);
      final result = detection(now,
              x: side == 'LEFT'
                  ? .05
                  : side == 'CENTER'
                      ? .4
                      : .75)
          .toDetectionResult();
      a.observe(result, age: Duration.zero);
      await flush(t);
      expect(port.active!['direction'], side);
      expect(tts.spoken, isEmpty);
      expect(a.diagnostic['className'], '버스');
      port.finish();
      await flush(t);
      expect(tts.spoken.length, 1);
      expect(tts.spoken.single, contains('버스'));
      expect(tts.spoken.single, contains('화면'));
      expect(tts.spoken.single, contains('실제 거리와 이동 방향은 알 수 없습니다'));
      now = 4000000;
      await t.pump(const Duration(seconds: 4));
      await flush(t);
      expect(a.busy,
          isTrue); // A valid admitted sentence outlives frame freshness.
      tts.finish();
      await flush(t);
      expect(a.completed, 1);
      now = 12000000;
      a.observe(
          detection(now,
                  x: side == 'LEFT'
                      ? .05
                      : side == 'CENTER'
                          ? .4
                          : .75)
              .toDetectionResult(),
          age: Duration.zero);
      await flush(t);
      expect(a.admitted, 1); // Continuous same meaning, no repeated speech.
      a.dispose();
      await realEngine.dispose();
      priority.dispose();
      expect(t.takeException(), isNull);
    });
  }
  for (final scenario in [
    'disabled',
    'empty',
    'low-confidence',
    'bad-bbox',
    'wrong-name',
    'expired',
    'unsupported'
  ]) {
    testWidgets('screen audio excludes $scenario fixture', (t) async {
      final port = native.Port(), tts = speech.FakeTts();
      final engine = SpatialVerificationEngine(
          NativeDirectionalCueOutput(port: port), tts);
      final priority = SpeechPriorityCoordinator(engine);
      final a = VisionScreenAudio(
          priority: priority,
          engine: engine,
          sessionGeneration: 's',
          isCurrent: () => true);
      if (scenario != 'disabled') a.setEnabled(true);
      final result = detection(0,
              confidence: scenario == 'low-confidence' ? .49 : .9,
              boxes: scenario == 'empty' ? [] : null)
          .toDetectionResult();
      final rows = result['detections'] as List;
      if (scenario == 'bad-bbox') (rows.first['bbox'] as Map)['x'] = -1.0;
      if (scenario == 'wrong-name') rows.first['className'] = '버스 문';
      if (scenario == 'unsupported') rows.first['classId'] = 'imaginary-door';
      a.observe(result,
          age: scenario == 'expired'
              ? const Duration(seconds: 2)
              : Duration.zero);
      await flush(t);
      expect(port.calls.where((c) => c == 'play'), isEmpty);
      expect(tts.spoken, isEmpty);
      a.dispose();
      await engine.dispose();
      priority.dispose();
    });
  }
  for (final action in [
    'stop-cue',
    'stop-tts',
    'hold-cue',
    'hold-tts',
    'session-end',
    'dispose',
    'watchdog'
  ]) {
    testWidgets('screen audio lifecycle $action', (t) async {
      final port = native.Port(), tts = speech.FakeTts();
      final engine = SpatialVerificationEngine(
          NativeDirectionalCueOutput(port: port), tts);
      final priority = SpeechPriorityCoordinator(engine);
      var current = true;
      final a = VisionScreenAudio(
          priority: priority,
          engine: engine,
          sessionGeneration: 's',
          isCurrent: () => current);
      a.setEnabled(true);
      a.observe(detection(0).toDetectionResult(), age: Duration.zero);
      await flush(t);
      final old = Map<String, dynamic>.from(port.active!);
      if (action.endsWith('tts') || action == 'watchdog') {
        port.finish();
        await flush(t);
        expect(tts.spoken.length, 1);
      }
      if (action.startsWith('hold')) {
        await a.toggleHold();
        await flush(t);
        await a.toggleHold();
      } else if (action == 'session-end') {
        current = false;
        await a.stop();
      } else if (action == 'dispose') {
        a.dispose();
      } else if (action == 'watchdog') {
        await t.pump(const Duration(seconds: 31));
        await flush(t);
        expect(a.enabled, isFalse);
      } else {
        await a.stop();
      }
      await flush(t);
      port.controller.add({...old, 'completed': true});
      await flush(t);
      expect(port.active, isNull);
      expect(tts.spoken.length,
          action.endsWith('tts') || action == 'watchdog' ? 1 : 0);
      a.dispose();
      await engine.dispose();
      priority.dispose();
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
      'expired first admission does not consume future fresh observation',
      (t) async {
    final port = native.Port()..prepareGate = Completer<void>();
    final tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    var now = 0;
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true,
        nowMicros: () => now);
    a.setEnabled(true);
    a.observe(detection(0).toDetectionResult(), age: Duration.zero);
    await flush(t);
    now = 3000000;
    port.prepareGate!.complete();
    await flush(t);
    expect(port.active, isNull);
    expect(a.admitted, 0);
    expect(a.enabled, isTrue);
    a.observe(detection(now).toDetectionResult(), age: Duration.zero);
    await flush(t);
    expect(port.active, isNotNull);
    expect(a.admitted, 1);
    await a.stop();
    a.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets(
      'late stop after timeout and disposal keeps quarantine and no TTS',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true);
    a.setEnabled(true);
    a.observe(detection(0).toDetectionResult(), age: Duration.zero);
    await flush(t);
    port.stopGate = Completer<void>();
    final stopping = a.stop();
    await t.pump(const Duration(milliseconds: 3100));
    await flush(t);
    await stopping;
    expect(priority.outputUncertain, isTrue);
    expect(tts.spoken, isEmpty);
    a.dispose();
    priority.dispose();
    port.stopGate!.complete();
    await flush(t);
    await engine.dispose();
    expect(t.takeException(), isNull);
    expect(port.active, isNull);
  });
  testWidgets('auth or session guard retires Cue completion before TTS',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    var current = true;
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => current);
    a.setEnabled(true);
    a.observe(detection(0).toDetectionResult(), age: Duration.zero);
    await flush(t);
    current = false;
    port.finish();
    await flush(t);
    expect(tts.spoken, isEmpty);
    a.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets(
      'FramePump fixture remains nonblocking and chooses one highest-confidence object',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    var now = 0;
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true,
        nowMicros: () => now);
    final sent = <String>[];
    final pump = FramePump(
        (f) async => LocalObservation(
            f,
            Uint8List(0),
            [
              const LocalBox('bus', .6, .05, .2, .2, .2),
              const LocalBox('bus_door', .9, .75, .2, .2, .2)
            ],
            2,
            2,
            1,
            2),
        () => now, onResult: (value) async {
      sent.add(value.frame.frameId);
    });
    pump.addListener(() {
      final item = pump.observation;
      if (item != null) a.observe(item.toDetectionResult(), age: Duration.zero);
    });
    a.setEnabled(true);
    pump.start();
    pump.submit(camera.frame(now));
    await flush(t);
    expect(port.active!['direction'], 'RIGHT');
    expect(a.diagnostic['className'], '버스 문');
    now = 1;
    pump.submit(camera.frame(now));
    await flush(t);
    expect(pump.processed, 2);
    expect(sent.length, 2);
    expect(a.admitted, 1);
    expect(a.skippedBusy, greaterThan(0));
    await a.stop();
    await pump.stop();
    pump.dispose();
    a.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets(
      'camera screen controls use the existing Coordinator for STOP and Hold',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: VisionScreenAudioPanel(audio: a, cameraActive: true))));
    await t.tap(find.byType(Switch));
    a.observe(detection(0).toDetectionResult(), age: Duration.zero);
    await flush(t);
    await t.tap(find.text('화면 음향 STOP'));
    await flush(t);
    expect(a.enabled, isFalse);
    expect(port.active, isNull);
    expect(tts.spoken, isEmpty);
    await t.tap(find.text('화면 음향 Live Hold'));
    await flush(t);
    expect(priority.priorityActive, isTrue);
    await t.tap(find.text('화면 음향 Hold 해제'));
    await flush(t);
    expect(priority.priorityActive, isFalse);
    await t.pumpWidget(const SizedBox());
    a.dispose();
    await engine.dispose();
    priority.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'invalid sensor stops active HRTF and only a new frame may use stereo fallback',
      (t) async {
    final port = native.Port(), headPort = _HeadPort(), tts = speech.FakeTts();
    final engine = SpatialVerificationEngine(
        NativeDirectionalCueOutput(port: port, headTrackedPort: headPort), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final sensor = HeadTrackingState();
    var now = 0;
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true,
        headTracking: sensor,
        horizontalFovDegrees: 90,
        nowMicros: () => now);
    a.setEnabled(true);
    a.setHeadTrackingMount(HeadTrackingCameraMount.fixedWorldCamera);
    a.setMountAlignment(verified: true, cameraAxisOffsetDegrees: 0);
    sensor.publish(HeadTrackingSnapshot(
        status: HeadTrackingStatus.ready,
        rawYaw: 10,
        filteredYaw: 10,
        referenceYaw: 0,
        receivedAt: DateTime.now().toUtc()));
    a.setHeadTrackingEnabled(true);
    expect(a.headTrackingEnabled, isTrue);

    a.observe(detection(0, x: .05).toDetectionResult(), age: Duration.zero);
    await flush(t);
    expect(headPort.calls, contains('start'));
    expect(port.active, isNull);

    sensor.publish(
        const HeadTrackingSnapshot(status: HeadTrackingStatus.disconnected));
    await flush(t);
    expect(headPort.calls, contains('stop'));
    expect(a.headTrackingEnabled, isFalse);
    expect(a.enabled, isTrue);
    expect(tts.spoken, isEmpty);
    await t.pump(const Duration(milliseconds: 600));
    await flush(t);

    now = const Duration(seconds: 9).inMicroseconds;
    a.observe(detection(now, x: .75).toDetectionResult(), age: Duration.zero);
    await flush(t);
    expect(port.active?['direction'], 'RIGHT');
    expect(headPort.calls.where((v) => v == 'start').length, 1);
    await a.stop();
    a.dispose();
    await engine.dispose();
    priority.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets('mount choice alone and missing FOV cannot activate HRTF',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final sensor = HeadTrackingState();
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true,
        headTracking: sensor,
        horizontalFovDegrees: 0);
    sensor.publish(HeadTrackingSnapshot(
        status: HeadTrackingStatus.ready,
        rawYaw: 0,
        filteredYaw: 0,
        referenceYaw: 0,
        receivedAt: DateTime.now().toUtc()));

    a.setHeadTrackingMount(HeadTrackingCameraMount.fixedWorldCamera);
    a.setHeadTrackingEnabled(true);
    expect(a.headTrackingEnabled, isFalse);
    a.setMountAlignment(verified: true, cameraAxisOffsetDegrees: 0);
    a.setHeadTrackingEnabled(true);
    expect(a.headTrackingEnabled, isFalse);
    a.setHeadTrackingMount(HeadTrackingCameraMount.handheldPhone);
    a.setMountAlignment(verified: true, cameraAxisOffsetDegrees: 0);
    a.setHeadTrackingEnabled(true);
    expect(a.headTrackingEnabled, isFalse);

    a.dispose();
    await engine.dispose();
    priority.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets(
      '3-frame consecutive confirmation and 70% door-in-bus overlap filter work as expected',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    var now = 0;
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true,
        confirmationFrames: 3,
        requireDoorInBus: true,
        nowMicros: () => now);
    a.setEnabled(true);

    // 1. Standalone bus_door (no bus overlap) should be filtered out even after 3 frames.
    for (var i = 1; i <= 3; i++) {
      now = i;
      a.observe(
          detection(now, boxes: [
            const LocalBox('bus_door', .95, .4, .2, .2, .3),
          ]).toDetectionResult(),
          age: Duration.zero);
      await flush(t);
    }
    expect(a.admitted, 0);
    expect(port.active, isNull);

    // 2. Jittering direction resets streak before reaching 3 frames.
    a.observe(detection(10, x: .05).toDetectionResult(), age: Duration.zero);
    a.observe(detection(11, x: .05).toDetectionResult(), age: Duration.zero);
    a.observe(detection(12, x: .75).toDetectionResult(), age: Duration.zero);
    await flush(t);
    expect(a.admitted, 0);

    // 3. Valid bus_door inside bus (>=70% overlap) confirmed for 3 consecutive frames admits cue.
    for (var i = 20; i < 23; i++) {
      now = i;
      a.observe(
          detection(now, boxes: [
            const LocalBox('bus', .85, .1, .1, .8, .8),
            const LocalBox('bus_door', .92, .4, .2, .2, .3),
          ]).toDetectionResult(),
          age: Duration.zero);
      await flush(t);
    }
    expect(a.admitted, 1);
    expect(a.diagnostic['className'], '버스 문');
    expect(port.active?['direction'], 'CENTER');

    await a.stop();
    a.dispose();
    await engine.dispose();
    priority.dispose();
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'prioritizeByDistance selects nearer obstacle over distant bus with higher confidence',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    var now = 0;
    final a = VisionScreenAudio(
        priority: priority,
        engine: engine,
        sessionGeneration: 's',
        isCurrent: () => true,
        prioritizeByDistance: true,
        nowMicros: () => now);
    a.setEnabled(true);

    // Distant bus (confidence 0.96, FAR) vs near kickboard obstacle (confidence 0.75, NEAR).
    a.observe(
        detection(1, boxes: [
          const LocalBox('bus', .96, .05, .1, .15, .15),
          const LocalBox('parked_pm', .75, .70, .55, .25, .35),
        ]).toDetectionResult(),
        age: Duration.zero);
    await flush(t);
    expect(a.admitted, 1);
    expect(a.diagnostic['classId'], 'parked_pm');
    expect(a.diagnostic['className'], '방치 전동 킥보드');
    expect(a.diagnostic['relativeDistance'], 'NEAR');
    expect(port.active?['direction'], 'RIGHT');

    await a.stop();
    a.dispose();
    await engine.dispose();
    priority.dispose();
    expect(t.takeException(), isNull);
  });
}
