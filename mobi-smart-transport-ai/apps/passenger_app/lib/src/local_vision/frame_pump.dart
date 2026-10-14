import 'dart:async';
import 'package:flutter/foundation.dart';
import 'vision_codec.dart';

/// One in-flight inference and at most one replaceable pending frame.
class FramePump extends ChangeNotifier {
  FramePump(this.infer, this.nowMicros,
      {this.ttl = const Duration(seconds: 2)});
  final Future<LocalObservation> Function(VisionFrame) infer;
  final int Function() nowMicros;
  final Duration ttl;
  VisionFrame? _latest;
  bool active = false, _busy = false, _disposed = false;
  int _generation = 0;
  Completer<void>? _idle;
  Timer? _expiry;
  LocalObservation? observation;
  String? error;
  bool lost = false;
  int? _lastReceived;
  int received = 0, processed = 0, replaced = 0, expired = 0;

  void start() {
    if (_disposed || _busy) throw StateError('이전 추론이 종료되지 않았습니다.');
    _generation++;
    active = true;
    lost = false;
    _lastReceived = nowMicros();
    error = null;
    received = processed = replaced = expired = 0;
    _expiry?.cancel();
    _expiry =
        Timer.periodic(const Duration(milliseconds: 100), (_) => expire());
  }

  void expire() {
    final nextLost = active &&
        _lastReceived != null &&
        nowMicros() - _lastReceived! >= ttl.inMicroseconds;
    if (lost != nextLost) {
      lost = nextLost;
      _notify();
    }
    final item = observation;
    if (item != null &&
        nowMicros() - item.frame.receivedMicros >= ttl.inMicroseconds) {
      observation = null;
      _notify();
    }
  }

  void submit(VisionFrame frame) {
    if (!active || _disposed) return;
    _lastReceived = frame.receivedMicros;
    if (lost) {
      lost = false;
      _notify();
    }
    received++;
    if (_latest != null) replaced++;
    _latest = frame;
    if (!_busy) unawaited(_drain());
  }

  Future<void> _drain() async {
    _busy = true;
    _idle = Completer<void>();
    final generation = _generation;
    try {
      while (active && generation == _generation && _latest != null) {
        final frame = _latest!;
        _latest = null;
        if (nowMicros() - frame.receivedMicros >= ttl.inMicroseconds) {
          expired++;
          continue;
        }
        try {
          final value = await infer(frame);
          if (!active || generation != _generation) break;
          if (value.frame.receivedMicros != frame.receivedMicros ||
              value.frame.receivedAt != frame.receivedAt) {
            throw StateError("프레임 식별 정보 불일치");
          }
          if (nowMicros() - frame.receivedMicros >= ttl.inMicroseconds) {
            expired++;
            observation = null;
          } else {
            observation = value;
            processed++;
          }
          _notify();
        } catch (_) {
          if (active && generation == _generation) {
            error = '모바일 추론 실패 · 카메라를 다시 시작해 주세요';
            active = false;
            observation = null;
            _latest = null;
            _expiry?.cancel();
            _notify();
          }
          break;
        }
      }
    } finally {
      _busy = false;
      _idle?.complete();
    }
  }

  Future<void> stop() async {
    active = false;
    _generation++;
    _latest = null;
    observation = null;
    _expiry?.cancel();
    _notify();
    await _idle?.future;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    active = false;
    _generation++;
    _latest = null;
    observation = null;
    _expiry?.cancel();
    super.dispose();
  }
}
