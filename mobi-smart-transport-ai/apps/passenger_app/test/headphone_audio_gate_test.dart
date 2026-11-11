import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/headphone_audio_gate.dart';
import 'package:mobi_passenger_app/src/services/speech_engine.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'door_approach_demo_test.dart' as f;

class Voice implements SpeechEngine {
  final texts = <String>[];
  bool hold = false;
  int stops = 0;
  Completer<void>? pending;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) {
    texts.add(text);
    if (!hold) return Future.value();
    pending = Completer<void>();
    return pending!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (pending?.isCompleted == false) pending!.complete();
  }
}

void main() {
  test('no headphone blocks cues and TTS; connect alone never arms playback',
      () async {
    final output = f.CuePort(), voice = Voice();
    final changes = StreamController<bool>.broadcast(sync: true);
    var connected = false;
    final gate = HeadphoneAudioGate(
        output: output,
        voice: voice,
        available: () async => connected,
        changes: changes.stream);
    expect(await gate.arm(), false);
    await expectLater(
        gate.playCue(TestDirection.right), throwsA(isA<SpeechCancelled>()));
    await expectLater(gate.speak('blocked'), throwsA(isA<SpeechCancelled>()));
    connected = true;
    changes.add(true);
    await expectLater(
        gate.speak('still blocked'), throwsA(isA<SpeechCancelled>()));
    expect(voice.texts, isEmpty);
    expect(output.directions, isEmpty);
    expect(await gate.arm(), true);
    await gate.prepareFromGesture();
    await gate.playCue(TestDirection.left);
    await gate.speak('manual');
    expect(output.directions, [TestDirection.left]);
    expect(voice.texts, ['manual']);
    await gate.dispose();
    await changes.close();
  });
  test('disconnect stops active TTS and fresh commands require manual rearm',
      () async {
    final output = f.CuePort(), voice = Voice()..hold = true;
    final changes = StreamController<bool>.broadcast(sync: true);
    var connected = true, losses = 0;
    final gate = HeadphoneAudioGate(
        output: output,
        voice: voice,
        available: () async => connected,
        changes: changes.stream);
    final subscription = gate.losses.listen((_) => losses++);
    expect(await gate.arm(), true);
    final speaking = gate.speak('active');
    final check = expectLater(speaking, throwsA(isA<SpeechCancelled>()));
    await Future<void>.delayed(Duration.zero);
    expect(voice.texts, ['active']);
    connected = false;
    changes.add(false);
    await check;
    expect(losses, 1);
    expect(voice.stops, greaterThan(0));
    expect(output.stops, greaterThan(0));
    connected = true;
    changes.add(true);
    await expectLater(gate.speak('late'), throwsA(isA<SpeechCancelled>()));
    voice.hold = false;
    expect(await gate.arm(), true);
    await gate.speak('explicit restart');
    expect(voice.texts, ['active', 'explicit restart']);
    await subscription.cancel();
    await gate.dispose();
    await changes.close();
  });
  test('late native prepare cannot revive a disconnected request', () async {
    final output = f.CuePort()..preparing = Completer<void>();
    final voice = Voice();
    final changes = StreamController<bool>.broadcast(sync: true);
    final gate = HeadphoneAudioGate(
        output: output,
        voice: voice,
        available: () async => true,
        changes: changes.stream);
    expect(await gate.arm(), true);
    final preparing = gate.prepareFromGesture();
    final check = expectLater(preparing, throwsA(isA<SpeechCancelled>()));
    await Future<void>.delayed(Duration.zero);
    changes.add(false);
    output.preparing!.complete();
    await check;
    expect(output.directions, isEmpty);
    expect(voice.texts, isEmpty);
    await gate.dispose();
    await changes.close();
  });
  test('stale availability success after removal cannot start TTS', () async {
    final output = f.CuePort(), voice = Voice();
    final changes = StreamController<bool>.broadcast(sync: true);
    final delayed = Completer<bool>();
    var querying = false;
    final gate = HeadphoneAudioGate(
        output: output,
        voice: voice,
        available: () => querying ? delayed.future : Future.value(true),
        changes: changes.stream);
    expect(await gate.arm(), true);
    querying = true;
    final speaking = gate.speak('late snapshot');
    final check = expectLater(speaking, throwsA(isA<SpeechCancelled>()));
    changes.add(false);
    delayed.complete(true);
    await check;
    expect(voice.texts, isEmpty);
    await gate.dispose();
    await changes.close();
  });
  test('unconfirmed stop blocks rearm even after reconnect', () async {
    final output = f.CuePort(), voice = Voice();
    final changes = StreamController<bool>.broadcast(sync: true);
    final gate = HeadphoneAudioGate(
        output: output,
        voice: voice,
        available: () async => true,
        changes: changes.stream);
    expect(await gate.arm(), true);
    output.failStop = true;
    await expectLater(gate.stop(), throwsStateError);
    expect(await gate.arm(), false);
    output.failStop = false;
    await gate.dispose();
    await changes.close();
  });
}
