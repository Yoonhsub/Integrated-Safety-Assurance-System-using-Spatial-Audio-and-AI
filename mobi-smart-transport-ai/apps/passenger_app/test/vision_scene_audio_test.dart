import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/vision_screen_audio.dart';
import 'package:mobi_passenger_app/src/services/vision_scene_summary.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'native_android_audio_test.dart' as native;
import 'vision_observation_tts_test.dart' as speech;

Map<String, Object?> frame(int id,
        {bool multiple = true, bool empty = false}) =>
    {
      'status': 'ok',
      'source': 'android_camera',
      'frameId': 'scene-$id',
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'imageSize': {'width': 640, 'height': 640},
      'detections': empty
          ? []
          : [
              for (final x in multiple ? [.05, .45] : [.05])
                {
                  'classId': 'pole',
                  'className': '보도 기둥',
                  'confidence': .9,
                  'bbox': {'x': x, 'y': .2, 'w': .1, 'h': .2}
                }
            ],
    };
void main() {
  testWidgets(
      'multiple scene speaks all regions without directional cue; details fresh only',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final audio = VisionScreenAudio(
        sceneMode: true,
        priority: priority,
        engine: engine,
        sessionGeneration: 'scene',
        isCurrent: () => true,
        confirmationFrames: 1);
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await t.pump();
      }
    }

    audio.setEnabled(true);
    audio.observe(frame(1), age: Duration.zero);
    await flush();
    expect(audio.scene.status, VisionSceneStatus.multiple);
    expect(port.active, isNull);
    expect(tts.spoken.single, contains('왼쪽과 중앙'));
    expect(audio.diagnostic['proximity'], 'UNKNOWN');
    expect(audio.diagnostic.containsKey('relativeDistance'), isFalse);
    tts.finish();
    await flush();
    final detail = audio.describeScene();
    await flush();
    expect(tts.spoken.last, contains('보도 기둥'));
    tts.finish();
    await detail;
    await flush();
    await t.pump(const Duration(seconds: 2));
    await flush();
    expect(audio.scene.status, VisionSceneStatus.unavailable);
    expect(audio.canDescribeScene, isFalse);
    final count = tts.spoken.length;
    await audio.describeScene();
    expect(tts.spoken.length, count);
    audio.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets(
      'new uncertain scene cancels previous speech and STOP blocks pending details',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final audio = VisionScreenAudio(
        sceneMode: true,
        priority: priority,
        engine: engine,
        sessionGeneration: 'scene-stop',
        isCurrent: () => true,
        confirmationFrames: 1);
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await t.pump();
      }
    }

    audio.setEnabled(true);
    audio.observe(frame(1), age: Duration.zero);
    await flush();
    audio.observe(frame(2, empty: true), age: Duration.zero);
    await flush();
    expect(audio.scene.status, VisionSceneStatus.uncertain);
    expect(tts.stops, greaterThan(0));
    await audio.stop();
    await flush();
    final count = tts.spoken.length;
    await audio.describeScene();
    expect(tts.spoken.length, count);
    expect(audio.enabled, isFalse);
    audio.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets(
      'manual fresh detail works auto OFF and preserves receipt after STOP',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final audio = VisionScreenAudio(
        sceneMode: true,
        priority: priority,
        engine: engine,
        sessionGeneration: 'manual',
        isCurrent: () => true,
        confirmationFrames: 1);
    audio.observe(frame(1), age: Duration.zero);
    expect(audio.enabled, isFalse);
    expect(audio.canDescribeScene, isTrue);
    final receipt = audio.lastSceneReceivedAt;
    expect(receipt, isNotNull);
    final detail = audio.describeScene();
    for (var i = 0; i < 15; i++) {
      await t.pump();
    }
    expect(tts.spoken.single, contains('보도 기둥'));
    await audio.stop();
    await detail;
    expect(audio.canDescribeScene, isFalse);
    expect(audio.lastSceneReceivedAt, receipt);
    audio.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets('unsupported bus door makes required-parent scene uncertain',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final audio = VisionScreenAudio(
        sceneMode: true,
        priority: priority,
        engine: engine,
        sessionGeneration: 'door',
        isCurrent: () => true,
        confirmationFrames: 1,
        requireDoorInBus: true);
    final input = frame(1, multiple: false);
    final row = (input['detections'] as List).single as Map;
    row['classId'] = 'bus_door';
    row['className'] = '버스 문';
    audio.observe(input, age: Duration.zero);
    expect(audio.scene.status, VisionSceneStatus.uncertain);
    expect(audio.scene.groups, isEmpty);
    audio.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets(
      'confirmation is silent then first reliable scene starts without cooldown delay',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final audio = VisionScreenAudio(
        sceneMode: true,
        priority: priority,
        engine: engine,
        sessionGeneration: 'confirm',
        isCurrent: () => true,
        confirmationFrames: 3);
    final baseReceipt =
        DateTime.now().toUtc().subtract(const Duration(milliseconds: 500));
    audio.setEnabled(true);
    for (var i = 1; i <= 2; i++) {
      audio.observe(frame(i),
          age: const Duration(milliseconds: 500),
          receivedAt: baseReceipt.add(Duration(milliseconds: i * 10)));
      await t.pump();
      expect(tts.spoken, isEmpty);
      expect(audio.admitted, 0);
    }
    audio.observe(frame(3),
        receivedAt: baseReceipt.add(const Duration(milliseconds: 30)),
        age: const Duration(milliseconds: 500),
        inferenceMs: 12.5,
        processingMs: 18);
    for (var i = 0; i < 15; i++) {
      await t.pump();
    }
    expect(tts.spoken, hasLength(1));
    expect(audio.admitted, 1);
    expect(audio.diagnostic['inferenceMs'], 12.5);
    expect(audio.sceneOutputDiagnostic['phase'], 'TTS_START');
    expect(audio.sceneOutputDiagnostic['clockProvenance'],
        'SOFTWARE_CALLBACK_NOT_ACOUSTIC');
    await audio.stop();
    expect(audio.sceneOutputDiagnostic['phase'], 'STOP_REQUESTED');
    audio.dispose();
    await engine.dispose();
    priority.dispose();
  });
  testWidgets(
      'invalid result cannot reset watermark and resurrect older frames',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine =
        SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
    final priority = SpeechPriorityCoordinator(engine);
    final audio = VisionScreenAudio(
        sceneMode: true,
        priority: priority,
        engine: engine,
        sessionGeneration: 'late',
        isCurrent: () => true,
        confirmationFrames: 1);
    final latest =
        DateTime.now().toUtc().subtract(const Duration(milliseconds: 100));
    audio.observe(frame(1),
        age: const Duration(milliseconds: 100), receivedAt: latest);
    expect(audio.scene.status, VisionSceneStatus.multiple);
    audio.observe(frame(2),
        age: const Duration(milliseconds: 200),
        receivedAt: latest.subtract(const Duration(milliseconds: 100)));
    expect(audio.scene.status, VisionSceneStatus.unavailable);
    audio.observe(frame(3),
        age: const Duration(milliseconds: 150),
        receivedAt: latest.subtract(const Duration(milliseconds: 50)));
    expect(audio.scene.status, VisionSceneStatus.unavailable);
    expect(audio.lastSceneReceivedAt, latest);
    expect(tts.spoken, isEmpty);
    audio.dispose();
    await engine.dispose();
    priority.dispose();
  });
}
