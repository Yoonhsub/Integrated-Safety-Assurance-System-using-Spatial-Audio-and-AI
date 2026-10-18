import 'dart:async';
import 'speech_engine.dart';

/// Unknown shutdown is cancellation, never permission for voice fallback.
class AudioShutdownFailure extends SpeechCancelled {
  AudioShutdownFailure(this.cause);
  final Object cause;
  @override
  String toString() => '오디오 종료를 확인하지 못했습니다. 다시 중지하거나 앱을 다시 열어 주세요.';
}

/// A timeout does not cancel platform work. Reuse the same in-flight barrier;
/// late completion can release only this barrier's protection.
class AudioShutdown {
  AudioShutdown(
      {this.onHold,
      this.onConfirmed,
      this.timeout = const Duration(seconds: 3)});
  final void Function()? onHold, onConfirmed;
  final Duration timeout;
  Future<void>? _pending;
  bool _confirmed = true;
  bool get confirmed => _confirmed;
  void ensureReady() {
    if (!_confirmed) throw AudioShutdownFailure(StateError('shutdown pending'));
  }

  Future<void> run(List<Future<void> Function()> actions) {
    var operation = _pending;
    if (operation == null) {
      _confirmed = false;
      onHold?.call();
      operation =
          Future.wait(actions.map((action) => Future<void>.sync(action)))
              .then<void>((_) {});
      _pending = operation;
      final current = operation;
      unawaited(current.then<void>((_) {
        if (!identical(_pending, current)) return;
        _pending = null;
        _confirmed = true;
        onConfirmed?.call();
      }, onError: (Object _, StackTrace __) {
        if (identical(_pending, current)) _pending = null;
        // Retain protection. An explicit subsequent stop may retry.
      }));
    }
    return operation.timeout(timeout).catchError((Object error) {
      throw AudioShutdownFailure(error);
    });
  }
}

/// Observe page-owned asynchronous cleanup without asserting output success.
/// Timeout does not cancel native work or release any safety lease.
Future<void> observeAudioCleanup(Future<void> Function() cleanup,
    {required void Function(String message) report,
    required String channel,
    Duration timeout = const Duration(seconds: 3)}) async {
  try {
    await Future<void>.sync(cleanup).timeout(timeout);
  } catch (_) {
    // Never log engine payloads, user speech or credentials.
    report('$channel 종료를 확인하지 못했습니다. 출력 장치를 확인해 주세요.');
  }
}
