import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'directional_guidance.dart';
import 'spatial_verification_engine.dart';

abstract interface class NativeCuePort {
  Future<Map<String, dynamic>> invoke(String method, Map<String, dynamic> args);
  Stream<Map<String, dynamic>> get events;
}

/// One channel handler per Activity; old page disposal cannot remove a new handler.
class _AndroidCuePort implements NativeCuePort {
  _AndroidCuePort() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cueFinished' && call.arguments is Map) {
        _events.add(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }
  static final instance = _AndroidCuePort();
  final _channel = const MethodChannel('mobi/local_android_audio');
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    final result =
        await _channel.invokeMapMethod<String, dynamic>(method, args);
    if (result == null) {
      throw StateError('Native audio acknowledgement missing');
    }
    return result;
  }
}

/// Stereo only. No HRTF, head tracking, device forcing or microphone capture.
class NativeDirectionalCueOutput
    implements SpatialTestOutput, DirectionalCueOutput {
  NativeDirectionalCueOutput({NativeCuePort? port})
      : _port = port ?? _AndroidCuePort.instance,
        _owner = 'audio-${DateTime.now().microsecondsSinceEpoch}-${++_owners}' {
    _subscription = _port.events.listen(_event);
  }
  static int _owners = 0;
  final NativeCuePort _port;
  final String _owner;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  int _id = 0;
  bool _closed = false, _ready = false, _uncertain = false;
  Completer<bool>? _playing;
  Future<void>? _stopBarrier, _disposing;
  Map<String, dynamic> _probe = {
    'phase': 'idle',
    'active': false,
    'contextState': 'native-stereo'
  };
  Map<String, dynamic> _args([Map<String, dynamic> values = const {}]) =>
      {'owner': _owner, ...values};
  void recordTtsEvent(String value) {
    if (!_closed) _probe = {..._probe, 'ttsEvent': value};
  }

  void _ensureOpen() {
    if (_closed || _uncertain) {
      throw StateError('Native output closed or unconfirmed');
    }
  }

  @override
  Future<void> prepareFromGesture() async {
    _ensureOpen();
    final data = await _port.invoke('prepare', _args());
    _ensureOpen();
    _ready = true;
    _probe = {..._probe, ...data, 'phase': 'ready'};
  }

  @override
  Future<bool> play(String mode, String direction) {
    if (mode != 'STEREO') {
      throw UnsupportedError('Android stereo only; HRTF unverified');
    }
    final d = switch (direction) {
      'LEFT' => TestDirection.left,
      'CENTER' => TestDirection.center,
      'RIGHT' => TestDirection.right,
      _ => throw ArgumentError('Unknown test direction')
    };
    return playCue(d);
  }

  @override
  Future<bool> playCue(TestDirection direction) async {
    _ensureOpen();
    if (!_ready || _playing != null || _stopBarrier != null) {
      throw StateError('Prepare first; simultaneous cues forbidden');
    }
    final id = ++_id, pending = Completer<bool>();
    _playing = pending;
    // Native errors can arrive before the method reply. Preserve the error for
    // the caller while observing it immediately during that handshake.
    unawaited(pending.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _probe = {
      ..._probe,
      'phase': 'starting',
      'active': true,
      'runId': id,
      'direction': direction.name
    };
    try {
      final data = await _port.invoke(
          'play', _args({'id': id, 'direction': direction.name.toUpperCase()}));
      if (!_closed && id == _id && identical(_playing, pending)) {
        _probe = {..._probe, ...data, 'phase': 'playing'};
      }
    } catch (error, stack) {
      if (identical(_playing, pending)) {
        _playing = null;
        _uncertain = true;
        _probe = {
          ..._probe,
          'phase': 'failed',
          'active': 'unknown',
          'error': error.runtimeType.toString()
        };
        // Also observe a synchronous start failure; no unhandled Future error.
        if (!pending.isCompleted) pending.complete(false);
      }
      Error.throwWithStackTrace(error, stack);
    }
    return pending.future;
  }

  void _event(Map<String, dynamic> data) {
    if (_closed || data['owner'] != _owner || data['id'] != _id) return;
    final pending = _playing;
    if (pending == null) return;
    _playing = null;
    final ok = data['completed'] == true;
    _probe = {
      ..._probe,
      ...data,
      'active': false,
      'phase': ok ? 'completed' : 'cancelled'
    };
    if (data['error'] == true) {
      _uncertain = true;
      pending
          .completeError(StateError('Native cue failure: ${data['reason']}'));
    } else {
      pending.complete(ok);
    }
  }

  void _retire() {
    _id++;
    final pending = _playing;
    _playing = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  @override
  Future<void> stop() {
    if (_disposing != null) return _disposing!;
    if (_stopBarrier != null) return _stopBarrier!;
    _retire();
    _uncertain = true;
    final operation = () async {
      final data = await _port.invoke('stop', _args());
      if (data['confirmed'] != true) {
        throw StateError('Native stop not confirmed');
      }
      _uncertain = false;
      if (!_closed) {
        _probe = {..._probe, ...data, 'phase': 'stopped', 'active': false};
      }
    }();
    _stopBarrier = operation;
    return operation.whenComplete(() {
      if (identical(_stopBarrier, operation)) _stopBarrier = null;
    });
  }

  @override
  Future<void> dispose() {
    if (_disposing != null) return _disposing!;
    _closed = true;
    _retire();
    _probe = {..._probe, 'phase': 'closing'};
    return _disposing = () async {
      // Listener retirement is immediate; its asynchronous cleanup must not
      // delay actual output release. _closed already rejects every late event.
      unawaited(_subscription.cancel().catchError((Object error) {
        debugPrint('Native audio event cleanup failure: ${error.runtimeType}');
      }));
      final data = await _port.invoke('dispose', _args());
      if (data['confirmed'] != true) {
        throw StateError('Native dispose not confirmed');
      }
      _probe = {
        ..._probe,
        ...data,
        'phase': 'closed',
        'contextState': 'closed',
        'active': false
      };
    }();
  }

  @override
  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(_probe);
}
