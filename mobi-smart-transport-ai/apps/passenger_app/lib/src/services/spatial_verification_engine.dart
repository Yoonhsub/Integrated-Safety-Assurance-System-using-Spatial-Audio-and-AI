import 'dart:async';
import 'speech_priority_coordinator.dart';
import 'directional_guidance.dart';

/// Verification-only graph, sharing the existing Web Audio context.
abstract interface class SpatialTestOutput {
  Future<void> prepareFromGesture();
  Future<bool> play(String mode, String direction);
  Future<void> stop();
  Future<void> dispose();
  Map<String, dynamic> snapshot();
}

/// Short directional cue capability; existing SpatialTestOutput stays compatible.
abstract interface class DirectionalCueOutput {
  Future<bool> playCue(TestDirection direction);
}

class _GuidanceRequest {
  _GuidanceRequest(this.guidance, this.isCurrent);
  final DirectionalGuidance guidance;
  final bool Function() isCurrent;
}

/// One coordinator and one active source for both test buffers and real TTS.
/// Reserved commands exist only in the explicit local debug entry.
class SpatialVerificationEngine implements SpeechEngine {
  SpatialVerificationEngine(this.output, this.tts, {this.onGuidanceTrace});
  final void Function(String guidanceId, String phase)? onGuidanceTrace;
  final Map<String, _GuidanceRequest> _guidanceRequests = {};
  final Set<String> _seen = {};
  int _nextGuidance = 0;

  /// Pinned lifecycle guard includes auth epoch, session generation and priority.
  /// Reserve before entering the coordinator so duplicates cannot preempt output.
  String? registerGuidance(
      DirectionalGuidance guidance, bool Function() isCurrent) {
    guidance.validate();
    if (_disposed || !isCurrent() || _seen.contains(guidance.scopeKey)) {
      return null;
    }
    if (_guidanceRequests.length >= 128) {
      throw StateError('Local Guidance request limit');
    }
    _seen.add(guidance.scopeKey);
    if (_seen.length > 128) _seen.remove(_seen.first);
    final command = '@guidance:${++_nextGuidance}';
    _guidanceRequests[command] = _GuidanceRequest(guidance, isCurrent);
    return command;
  }

  void retireGuidance(String command) => _guidanceRequests.remove(command);
  void _guidanceCheck(_GuidanceRequest request, int revision) {
    if (_disposed || revision != _revision || !request.isCurrent()) {
      throw SpeechCancelled();
    }
  }

  void _trace(_GuidanceRequest request, String phase) {
    if (!_disposed) onGuidanceTrace?.call(request.guidance.guidanceId, phase);
  }

  Future<void> _speakGuidance(_GuidanceRequest request, int revision) async {
    final guidance = request.guidance;
    _guidanceCheck(request, revision);
    if (guidance.hasReviewedDirection) {
      if (output is! DirectionalCueOutput) {
        throw StateError('Short Cue capability missing');
      }
      await output.prepareFromGesture();
      _guidanceCheck(request, revision);
      _trace(request, 'CUE_START');
      _guidanceCheck(request, revision);
      final complete = await (output as DirectionalCueOutput)
          .playCue(guidance.testDirection!);
      _guidanceCheck(request, revision);
      if (!complete) throw SpeechCancelled();
      _trace(request, 'CUE_COMPLETED');
      // A successful source completion alone is not permission for TTS overlap.
      await output.stop();
      _guidanceCheck(request, revision);
      _trace(request, 'CUE_STOP_CONFIRMED');
    }
    await tts.prepare(requireKoreanVoice: true);
    _guidanceCheck(request, revision);
    _trace(request, 'TTS_START');
    _guidanceCheck(request, revision);
    await tts.speak(guidance.spokenText);
    _guidanceCheck(request, revision);
    _trace(request, 'TTS_COMPLETED');
  }

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
    if (text.startsWith('@guidance:')) {
      final request = _guidanceRequests.remove(text);
      if (request == null) throw SpeechCancelled();
      await _speakGuidance(request, revision);
    } else if (text.startsWith('@spatial:')) {
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
    _guidanceRequests.clear();
    _seen.clear();
    // Force context close independently of an unresponsive stop operation.
    await Future.wait([output.dispose(), tts.stop()])
        .timeout(const Duration(seconds: 3));
  }
}
