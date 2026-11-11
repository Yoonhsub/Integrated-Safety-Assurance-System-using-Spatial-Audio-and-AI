import 'dart:async';
import 'directional_guidance.dart';
import 'spatial_verification_engine.dart';
import 'speech_engine.dart';

/// Local rehearsal connection gate. It checks connected headphone endpoints;
/// it does not claim to measure the TTS engine's actual routed device.
class HeadphoneAudioGate
    implements SpatialTestOutput, DirectionalCueOutput, SpeechEngine {
  HeadphoneAudioGate(
      {required this.output,
      required this.voice,
      required this.available,
      required Stream<bool> changes}) {
    _subscription = changes.listen((connected) {
      if (!connected) _lose(); // true never arms or starts output.
    }, onError: (Object _) => _lose(), onDone: _lose);
  }
  final SpatialTestOutput output;
  final SpeechEngine voice;
  final Future<bool> Function() available;
  late final StreamSubscription<bool> _subscription;
  final _losses = StreamController<void>.broadcast(sync: true);
  Stream<void> get losses => _losses.stream;
  bool _armed = false, _closed = false, _broken = false;
  int _revision = 0;
  Future<void>? _stopping, _disposing;

  /// Called only by the explicit user start button, never by playback callbacks.
  Future<bool> arm() async {
    if (_closed || _broken) return false;
    final revision = _revision;
    try {
      await _stopping;
      final connected = await available().timeout(const Duration(seconds: 2));
      if (_closed || _broken || revision != _revision) return false;
      _armed = connected;
      return connected;
    } catch (_) {
      _lose();
      return false;
    }
  }

  void _valid(int revision) {
    if (_closed || _broken || !_armed || revision != _revision) {
      throw SpeechCancelled();
    }
  }

  Future<int> _check() async {
    final revision = _revision;
    _valid(revision);
    bool connected;
    try {
      connected = await available().timeout(const Duration(seconds: 2));
    } catch (_) {
      _lose();
      rethrow;
    }
    if (!connected) {
      _lose();
      throw SpeechCancelled();
    }
    _valid(revision);
    return revision;
  }

  void _lose() {
    if (_closed) return;
    final wasArmed = _armed;
    _armed = false;
    ++_revision;
    if (wasArmed) _losses.add(null); // Disarm the page before async cleanup.
    unawaited(stop().catchError((Object _) {
      _broken = true;
    }));
  }

  @override
  Future<void> prepareFromGesture() async {
    final revision = await _check();
    await output.prepareFromGesture();
    _valid(revision);
  }

  @override
  Future<bool> playCue(TestDirection direction) async {
    final revision = await _check();
    if (output is! DirectionalCueOutput) {
      throw StateError('Directional output required');
    }
    final result = await (output as DirectionalCueOutput).playCue(direction);
    _valid(revision);
    return result;
  }

  @override
  Future<bool> play(String mode, String direction) async {
    final revision = await _check();
    final result = await output.play(mode, direction);
    _valid(revision);
    return result;
  }

  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {
    final revision = await _check();
    await voice.prepare(requireKoreanVoice: requireKoreanVoice);
    _valid(revision);
  }

  @override
  Future<void> speak(String text) async {
    final revision = await _check();
    await voice.speak(text);
    _valid(revision);
  }

  @override
  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    ++_revision;
    final operation = Future.wait([output.stop(), voice.stop()])
        .timeout(const Duration(seconds: 3))
        .then<void>((_) {}, onError: (Object e, StackTrace s) {
      _broken = true;
      Error.throwWithStackTrace(e, s);
    });
    _stopping = operation;
    return operation.whenComplete(() {
      if (identical(_stopping, operation)) _stopping = null;
    });
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    _armed = false;
    ++_revision;
    try {
      await stop();
    } finally {
      await Future.wait(
          [_subscription.cancel(), output.dispose(), _losses.close()]);
    }
  }

  @override
  Map<String, dynamic> snapshot() => {
        ...output.snapshot(),
        'headphoneGateArmed': _armed,
        'headphoneGateBroken': _broken
      };
}
