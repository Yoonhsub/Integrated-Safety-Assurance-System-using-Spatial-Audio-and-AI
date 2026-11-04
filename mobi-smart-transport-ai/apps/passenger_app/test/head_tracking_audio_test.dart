import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_engine.dart';

class _NativePort implements NativeCuePort {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    if (method == 'prepare') return {'confirmed': true};
    if (method == 'stop' || method == 'dispose') {
      return {'confirmed': true, 'active': false};
    }
    throw StateError('unexpected local cue $method');
  }
}

class _HrtfPort implements HeadTrackedCuePort {
  final calls = <String>[];
  double? azimuth;
  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    calls.add(method);
    if (method == 'start') {
      azimuth = args['azimuthDegrees'] as double;
      return {'running': true, 'spatial': true, 'route': 'test'};
    }
    if (method == 'stop') {
      return {'confirmed': true, 'running': false};
    }
    throw StateError('unexpected HRTF call $method');
  }
}

class _Tts implements SpeechEngine {
  final spoken = <String>[];
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  Future<void> stop() async {}
}

void main() {
  test('head-tracked HRTF cue completes before normal TTS', () async {
    final native = _NativePort(), hrtf = _HrtfPort(), tts = _Tts();
    final output =
        NativeDirectionalCueOutput(port: native, headTrackedPort: hrtf);
    final engine = SpatialVerificationEngine(output, tts);
    final guidance = DirectionalGuidance(
      guidanceId: 'frame-1',
      sessionGeneration: 'session-1',
      authEpoch: 0,
      priority: GuidancePriority.observation,
      text: '버스가 감지되었습니다.',
      provenance: DirectionalGuidance.screenProvenance,
      testDirection: TestDirection.center,
      headTrackedAzimuthDegrees: -30,
      directionEvidence: DirectionEvidence.cameraScreenBbox,
    );
    final command = engine.registerGuidance(guidance, () => true);
    expect(command, isNotNull);
    await engine.speak(command!);
    expect(hrtf.calls, ['start', 'stop']);
    expect(hrtf.azimuth, -30);
    expect(tts.spoken, ['버스가 감지되었습니다.']);
    await engine.dispose();
    await native.controller.close();
  });

  test('STOP cancels HRTF cue and prevents following TTS', () async {
    final native = _NativePort(), hrtf = _HrtfPort(), tts = _Tts();
    final output =
        NativeDirectionalCueOutput(port: native, headTrackedPort: hrtf);
    final engine = SpatialVerificationEngine(output, tts);
    final guidance = DirectionalGuidance(
      guidanceId: 'frame-2',
      sessionGeneration: 'session-1',
      authEpoch: 0,
      priority: GuidancePriority.observation,
      text: '재생되면 안 됩니다.',
      provenance: DirectionalGuidance.screenProvenance,
      testDirection: TestDirection.center,
      headTrackedAzimuthDegrees: 30,
      directionEvidence: DirectionEvidence.cameraScreenBbox,
    );
    final command = engine.registerGuidance(guidance, () => true)!;
    final run = engine.speak(command);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await engine.stop();
    await expectLater(run, throwsA(isA<SpeechCancelled>()));
    expect(hrtf.calls.where((v) => v == 'stop'), isNotEmpty);
    expect(tts.spoken, isEmpty);
    await engine.dispose();
    await native.controller.close();
  });
}
