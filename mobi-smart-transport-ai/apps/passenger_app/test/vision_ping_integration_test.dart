import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/vision_screen_audio.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'native_android_audio_test.dart' as native;
import 'vision_observation_tts_test.dart' as speech;

Map<String, Object?> frame(int id, {bool empty = false, double x = .05}) => {
  'status': 'ok', 'source': 'android_camera', 'frameId': 'ping-$id',
  'capturedAt': DateTime.now().toUtc().toIso8601String(),
  'imageSize': {'width': 640, 'height': 640},
  'detections': empty ? [] : [
    {'classId': 'pole', 'className': '보도 기둥', 'confidence': .9,
      'bbox': {'x': x, 'y': .2, 'w': .2, 'h': .3}}
  ]
};

void main() {
  for (final ending in ['empty', 'stale', 'stop', 'hold', 'session']) {
    testWidgets('fresh detection ping repeats without TTS; $ending stops', (t) async {
      final port = native.Port(), tts = speech.FakeTts();
      final engine = SpatialVerificationEngine(NativeDirectionalCueOutput(port: port), tts);
      final priority = SpeechPriorityCoordinator(engine);
      var now = 0, current = true;
      final audio = VisionScreenAudio(priority: priority, engine: engine,
        sessionGeneration: 'ping', isCurrent: () => current,
        pingOnly: true, confirmationFrames: 1,
        minimumInterval: const Duration(seconds: 1), nowMicros: () => now);
      Future<void> flush() async { for (var i=0; i<15; i++) { await t.pump(); } }
      audio.setEnabled(true);
      audio.observe(frame(1), age: Duration.zero);
      await flush();
      expect(port.active?['direction'], 'LEFT');
      expect(audio.diagnostic['proximity'], 'UNKNOWN');
      expect(audio.diagnostic['risk'], 'NOT_ESTIMATED');
      port.finish(); await flush();
      expect(tts.spoken, isEmpty);
      expect(audio.completed, 1);
      audio.setEnabled(true); // Redundant enable must not reset live tracking.
      now = 1100000;
      await t.pump(const Duration(milliseconds: 1100));
      audio.observe(frame(2), age: Duration.zero);
      await flush();
      expect(port.active, isNotNull);
      switch (ending) {
        case 'empty': audio.observe(frame(3, empty: true), age: Duration.zero);
        case 'stale': await t.pump(const Duration(seconds: 2));
        case 'stop': await audio.stop();
        case 'hold': await audio.toggleHold();
        case 'session': current = false; await t.pump(const Duration(seconds: 2));
      }
      await flush();
      expect(port.active, isNull);
      expect(tts.spoken, isEmpty);
      audio.dispose(); await engine.dispose(); priority.dispose();
      expect(t.takeException(), isNull);
    });
  }
}
