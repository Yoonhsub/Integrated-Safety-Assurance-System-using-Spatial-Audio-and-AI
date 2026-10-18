import 'speech_engine.dart';

/// Page-owned scope. Invalidated synchronously before any asynchronous cleanup.
class SpeechRequestScope {
  int _generation = 0;
  bool _disposed = false;
  void invalidate() {
    _generation++;
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  /// A newer HTTP request supersedes every prior request in this scope.
  SpeechRequest captureLatest(bool Function() contextValid) {
    invalidate();
    return capture(contextValid);
  }

  SpeechRequest capture(bool Function() contextValid) {
    final generation = _generation;
    return SpeechRequest._(
        () => !_disposed && generation == _generation && contextValid());
  }
}

class SpeechRequest {
  SpeechRequest._(this._valid);
  final bool Function() _valid;
  bool get valid => _valid();
  void check() {
    if (!valid) throw SpeechCancelled();
  }

  /// Capture before HTTP starts; retire its result before any UI/audio action.
  Future<void> receive<T>(
          Future<T> Function() fetch, Future<void> Function(T value) accept) =>
      run(() async {
        final value = await fetch();
        check();
        await accept(value);
      });

  Future<void> run(Future<void> Function() primary,
      {Future<void> Function()? fallback}) async {
    if (!valid) return;
    try {
      await primary();
    } on SpeechCancelled {
      return;
    } catch (_) {
      if (!valid) return;
      if (fallback == null) rethrow;
      try {
        await fallback();
      } on SpeechCancelled {
        return;
      }
    }
  }
}
