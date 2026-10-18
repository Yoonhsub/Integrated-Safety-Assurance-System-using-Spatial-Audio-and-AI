import 'dart:async';
import 'dart:convert';
import 'audio_shutdown.dart';
import 'speech_engine.dart';

enum LiveAudioState {
  idle,
  starting,
  playing,
  cancelling,
  cancelled,
  completed,
  failed
}

abstract interface class LiveAudioOutput {
  Future<void> prepare();
  void start(int sampleRate);
  void feed(String pcm);
  Future<bool> finish();
  Future<void> stop();
}

abstract interface class LiveAudioConnection {
  set onOpen(void Function() callback);
  set onMessage(void Function(Object? message) callback);
  set onError(void Function() callback);
  set onClose(void Function() callback);
  void send(String text);
  void close();
}

class LiveAudioPlaybackException implements Exception {
  const LiveAudioPlaybackException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Request {
  _Request(this.id);
  final int id;
  final done = Completer<void>();
  LiveAudioConnection? socket;
  bool receivedDone = false, firstAudio = false;
}

/// Platform-independent production lifecycle, also used by the Web adapter.
class LiveAudioSession {
  LiveAudioSession(
      {required this.output,
      required this.connect,
      Duration shutdownTimeout = const Duration(seconds: 3),
      this.playbackTimeout = const Duration(seconds: 20)})
      : _shutdown = AudioShutdown(timeout: shutdownTimeout);
  final LiveAudioOutput output;
  final LiveAudioConnection Function(Uri) connect;
  final AudioShutdown _shutdown;
  final Duration playbackTimeout;
  int _generation = 0;
  bool _disposed = false;
  _Request? _active;
  LiveAudioState state = LiveAudioState.idle;
  int get generation => _generation;
  bool get shutdownConfirmed => _shutdown.confirmed;
  Future<void> prepare() => output.prepare();

  bool _valid(_Request r) =>
      !_disposed && r.id == _generation && identical(_active, r);
  void _check(_Request r) {
    if (!_valid(r)) throw SpeechCancelled();
  }

  void _retire() {
    final old = _active;
    _active = null;
    if (old == null) return;
    if (!old.done.isCompleted) old.done.completeError(SpeechCancelled());
    try {
      old.socket?.close();
    } catch (_) {/* Audio stop is still attempted. */}
  }

  Future<void> play(
      {required String baseUrl,
      required String text,
      void Function()? onFirstAudio}) async {
    if (_disposed) throw SpeechCancelled();
    final id = ++_generation;
    _retire();
    final r = _Request(id);
    // Observe retirement even while startup waits for platform shutdown.
    unawaited(r.done.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _active = r;
    state = LiveAudioState.starting;
    var natural = false;
    try {
      _check(r);
      await _shutdown.run([output.stop]);
      _check(r); // External stop invalidates startup synchronously.
      final socket = connect(_uri(baseUrl));
      r.socket = socket;
      _check(r);
      socket.onOpen = () {
        if (!_valid(r) || r.done.isCompleted) return;
        try {
          socket.send(jsonEncode({'text': text}));
        } catch (_) {
          _fail(r, '음성 연결 전송에 실패했습니다.');
        }
      };
      socket.onMessage = (message) {
        if (!_valid(r) || r.done.isCompleted || r.receivedDone) return;
        try {
          final decoded = message is String ? jsonDecode(message) : null;
          if (decoded is! Map) throw const FormatException();
          switch (decoded['type']) {
            case 'start':
              final rate = decoded['sampleRate'];
              if (rate is num && rate.isFinite && rate > 0) {
                _check(r);
                output.start(rate.toInt());
              }
              break;
            case 'audio':
              final audio = decoded['data'];
              if (audio is String && audio.isNotEmpty) {
                if (!r.firstAudio) {
                  r.firstAudio = true;
                  onFirstAudio?.call();
                }
                _check(r); // The callback may itself cancel/logout.
                state = LiveAudioState.playing;
                output.feed(audio);
              }
              break;
            case 'done':
              r.receivedDone = true;
              unawaited(output.finish().then<void>((value) {
                if (!_valid(r) || r.done.isCompleted) return;
                if (value) {
                  natural = true;
                  r.done.complete();
                } else {
                  r.done.completeError(SpeechCancelled());
                }
              }, onError: (Object _, StackTrace __) {
                _fail(r, '음성 재생 종료를 확인하지 못했습니다.');
              }));
              break;
            case 'error':
              _fail(r, '음성 서비스를 사용할 수 없습니다.');
              break;
          }
        } on SpeechCancelled {
          /* Retired request never outputs. */
        } catch (_) {
          _fail(r, '음성 메시지를 처리하지 못했습니다.');
        }
      };
      socket.onError = () => _fail(r, '음성 연결에 실패했습니다.');
      socket.onClose = () {
        if (!r.receivedDone) _fail(r, '음성 연결이 일찍 종료되었습니다.');
      };
      // All callbacks and the immediate output start belong to this request.
      _check(r);
      output.start(24000);
      await r.done.future.timeout(playbackTimeout);
      _check(r);
      state = LiveAudioState.completed;
    } catch (error) {
      if (_valid(r)) {
        state = error is SpeechCancelled
            ? LiveAudioState.cancelled
            : LiveAudioState.failed;
      }
      rethrow;
    } finally {
      if (identical(_active, r)) {
        _active = null;
        try {
          r.socket?.close();
        } catch (_) {}
        if (!natural) await _shutdown.run([output.stop]);
      }
    }
  }

  void _fail(_Request r, String text) {
    if (_valid(r) && !r.done.isCompleted) {
      r.done.completeError(LiveAudioPlaybackException(text));
    }
  }

  Future<void> stop() async {
    final stopping = ++_generation;
    state = LiveAudioState.cancelling;
    _retire();
    try {
      await _shutdown.run([output.stop]);
      // A late stop must not change a new request's state.
      if (_active == null && stopping == _generation) {
        state = LiveAudioState.cancelled;
      }
    } catch (_) {
      if (_active == null && stopping == _generation) {
        state = LiveAudioState.failed;
      }
      rethrow;
    }
  }

  Future<void> dispose() {
    _disposed = true;
    return stop();
  }

  Uri _uri(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    return uri.replace(
        scheme: uri.scheme == 'https' ? 'wss' : 'ws',
        path:
            '${uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path}/agent/tts/live',
        query: null,
        fragment: null);
  }
}
