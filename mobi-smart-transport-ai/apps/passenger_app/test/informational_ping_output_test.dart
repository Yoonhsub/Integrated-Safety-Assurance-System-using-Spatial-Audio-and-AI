import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'directional_guidance_test.dart' show CueOutput, message;
import 'vision_observation_tts_test.dart' show FakeTts;
import 'native_android_audio_test.dart' show Port;

class InformationOutput extends CueOutput
    implements InformationalDirectionalCueOutput {
  InformationalCueTone? tone;
  @override
  Future<bool> playInformationalCue(
      TestDirection direction, InformationalCueTone value) {
    tone = value;
    return playCue(direction);
  }
}

void main() {
  for (final cancelled in [false, true]) {
    testWidgets(
        'cue-only informational playback cancellation=$cancelled never speaks',
        (tester) async {
      final output = InformationOutput(), tts = FakeTts();
      final engine = SpatialVerificationEngine(output, tts);
      final priority = SpeechPriorityCoordinator(engine);
      final owner = Object();
      bool valid() => !priority.priorityActive;
      final command = engine.registerGuidance(
          message(
              provenance: DirectionalGuidance.screenProvenance,
              evidence: DirectionEvidence.cameraScreenBbox),
          valid,
          cueOnly: true,
          informationalTone: InformationalCueTone.obstacle)!;
      final result = priority.speakObservation(owner, command, valid);
      await tester.pump();
      expect(output.tone, InformationalCueTone.obstacle);
      expect(tts.spoken, isEmpty);
      if (cancelled) {
        final hold = priority.claimPriority();
        await tester.pump();
        expect(await result, isFalse);
        hold.release();
      } else {
        output.finish();
        await tester.pump();
        expect(await result, isTrue);
      }
      expect(tts.spoken, isEmpty);
      priority.dispose();
      await engine.dispose();
    });
  }
  test(
      'cue-only rejects unreviewed direction and tone rejects synthetic provenance',
      () {
    final engine = SpatialVerificationEngine(CueOutput(), FakeTts());
    expect(
        () => engine.registerGuidance(message(direction: null), () => true,
            cueOnly: true),
        throwsArgumentError);
    expect(
        () => engine.registerGuidance(message(), () => true,
            informationalTone: InformationalCueTone.obstacle),
        throwsArgumentError);
  });
  for (final tone in InformationalCueTone.values) {
    test('native informational ${tone.name} uses owned marker completion',
        () async {
      final port = Port(), output = NativeDirectionalCueOutput(port: Port());
      await output.dispose();
      final actual = NativeDirectionalCueOutput(port: port);
      await actual.prepareFromGesture();
      final result = actual.playInformationalCue(TestDirection.right, tone);
      await Future<void>.delayed(Duration.zero);
      expect(port.active!['informationalTone'], tone.name);
      expect(port.active!['direction'], 'RIGHT');
      expect(port.active!['owner'], isNotEmpty);
      port.finish();
      expect(await result, isTrue);
      await actual.stop();
      await actual.dispose();
    });
  }
}
