import 'dart:async';
import 'speech_priority_coordinator.dart';

/// Verification-only graph, sharing the existing Web Audio context.
abstract interface class SpatialTestOutput {
  Future<void> prepareFromGesture();
  Future<bool> play(String mode, String direction);
  Future<void> stop();
  Future<void> dispose();
  Map<String, dynamic> snapshot();
}

/// One coordinator and one active source for both test buffers and real TTS.
/// Reserved commands exist only in the explicit local debug entry.
class SpatialVerificationEngine implements SpeechEngine {
  SpatialVerificationEngine(this.output, this.tts);
  final SpatialTestOutput output;
  final SpeechEngine tts;
  int _revision = 0;
  bool _disposed = false;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {
    if (_disposed) throw StateError('Verification output disposed');
  }

  @override
  Future<void> speak(String text) async {
    if (_disposed) throw SpeechCancelled();
    final revision = ++_revision;
    if (text.startsWith('@spatial:')) {
      final fields = text.split(':');
      if (fields.length != 3) throw StateError('Invalid test command');
      await output.prepareFromGesture();
      if (_disposed || revision != _revision) throw SpeechCancelled();
      if (!await output.play(fields[1], fields[2])) throw SpeechCancelled();
    } else {
      await tts.prepare(requireKoreanVoice: true);
      if (_disposed || revision != _revision) throw SpeechCancelled();
      await tts.speak(text);
    }
  }

  @override
  Future<void> stop() async {
    _revision++;
    await Future.wait([output.stop(), tts.stop()]);
  }

  Future<void> dispose() async {
    _disposed = true;
    _revision++;
    // Force context close independently of an unresponsive stop operation.
    await Future.wait([output.dispose(), tts.stop()])
        .timeout(const Duration(seconds: 3));
  }
}
