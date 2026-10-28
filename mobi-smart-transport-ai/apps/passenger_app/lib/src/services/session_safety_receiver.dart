import 'dart:async';
import 'package:flutter/foundation.dart';
import 'speech_priority_coordinator.dart';

typedef SafetyFetch = Future<Map<String, dynamic>> Function(
    String, int?, String?);

abstract interface class SafetyPollingTransport {
  Future<Map<String, dynamic>> fetch(
      String sessionId, int? after, String? generation);
  void close();
}

class SafetyPollingException implements Exception {
  const SafetyPollingException({this.terminal = false, this.blocked = false});
  final bool terminal, blocked;
}

/// Session-local polling, using the existing authenticated API and audio arbiter.
/// Initial/reconnected polls establish a cursor, never replay earlier messages.
class SessionSafetyReceiver extends ChangeNotifier {
  SessionSafetyReceiver(
      {required this.sessionId,
      required this.ownerUid,
      required this.isCurrent,
      required this.fetch,
      required this.priority,
      bool allowSynthetic = false,
      Stream<Object?>? authChanges,
      this.cancelFetch,
      this.trace})
      : _allowSynthetic = allowSynthetic {
    if (allowSynthetic && kReleaseMode) {
      throw StateError('Synthetic guidance is test/debug only');
    }
    _authSubscription = authChanges?.listen((_) {
      if (!isCurrent() && !_closed) _invalidate();
    }, onError: (Object _) {
      if (!_closed) _invalidate();
    });
    priority.addListener(_priorityChanged);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      poll();
    });
    unawaited(poll());
  }
  final String sessionId, ownerUid;
  final bool Function() isCurrent;
  final SafetyFetch fetch;
  final VoidCallback? cancelFetch;
  final void Function(String)? trace;
  final SpeechPriorityCoordinator priority;
  final bool _allowSynthetic;
  final Object _audioOwner = Object();
  Timer? _timer, _expiry, _retry;
  int _failures = 0;
  StreamSubscription<Object?>? _authSubscription;
  bool _busy = false, _closed = false, enabled = false;
  int? _cursor;
  String? _generation;
  int _epoch = 0;
  String? message;
  String? _spokenMeaning;
  String status = '안전 이벤트 연결 중';
  bool get active => !_closed;

  void _priorityChanged() {
    if (priority.priorityActive) {
      _stop();
      notifyListeners();
    }
  }

  void setEnabled(bool value) {
    enabled = value;
    if (!value) _stop();
    notifyListeners();
  }

  void _stop() {
    message = null;
    _epoch++;
    _expiry?.cancel();
    unawaited(priority.stopObservation(_audioOwner).catchError((Object _) {}));
  }

  void close({bool notify = true}) {
    if (!_closed) _invalidate(notify: notify);
  }

  void _invalidate({bool notify = true}) {
    _closed = true;
    enabled = false;
    _timer?.cancel();
    _retry?.cancel();
    cancelFetch?.call();
    _stop();
    message = null;
    status = '세션 종료 · 안내 차단';
    if (notify) notifyListeners();
  }

  Future<void> poll() async {
    if (_closed) return;
    if (!isCurrent()) {
      _invalidate();
      return;
    }
    if (_busy || (_retry?.isActive ?? false)) return;
    _busy = true;
    final watch = Stopwatch()..start();
    try {
      final data = await fetch(sessionId, _cursor, _generation);
      if (_closed) return;
      if (!isCurrent()) {
        _invalidate();
        return;
      }
      final gen = data['generation'];
      final cursor = data['cursor'];
      if (data['sessionId'] != sessionId ||
          data['ownerUid'] != ownerUid ||
          gen is! String ||
          gen.isEmpty ||
          cursor is! int ||
          cursor < 0 ||
          data['events'] is! List) {
        throw const FormatException('Invalid safety scope');
      }
      if (_generation != null && _generation != gen) {
        _invalidate();
        return;
      }
      final baseline = _cursor == null;
      if (!baseline && cursor < _cursor!) {
        throw const FormatException('Reordered safety cursor');
      }
      final previous = _cursor ?? cursor;
      _cursor = cursor;
      _generation = gen;
      status = '안전 이벤트 연결됨';
      _failures = 0;
      if (baseline) trace?.call('polling_resumed');
      if (baseline) {
        _stop();
        message = null;
        notifyListeners();
        return;
      }
      // Consume all events before audio. Busy/priority/late events never queue.
      var sequence = previous;
      Map? latest;
      for (final raw in data['events'] as List) {
        if (raw is! Map ||
            raw['sequence'] is! int ||
            raw['sequence'] <= sequence ||
            raw['sequence'] > cursor ||
            raw['priority'] != 'info' ||
            raw['eventId'] is! String ||
            raw['message'] is! String ||
            raw['synthetic'] is! bool ||
            (raw['synthetic'] == true && !_allowSynthetic)) {
          throw const FormatException('Unreviewed safety event');
        }
        sequence = raw['sequence'] as int;
        final ttl = raw['validForSeconds'];
        if (ttl is! num || !ttl.isFinite || ttl <= 0 || ttl > 3) continue;
        latest = raw;
      }
      if (latest != null) {
        _stop();
        final ttl = (latest['validForSeconds'] as num).toDouble() -
            watch.elapsedMicroseconds / 1000000;
        if (ttl > 0) {
          message = latest['message'] as String;
          final epoch = _epoch;
          _expiry = Timer(Duration(microseconds: (ttl * 1000000).floor()), () {
            _stop();
            message = null;
            notifyListeners();
          });
          if (enabled &&
              !priority.priorityActive &&
              _spokenMeaning != message) {
            _spokenMeaning = message;
            unawaited(priority
                .speakObservation(_audioOwner, message!,
                    () => !_closed && enabled && epoch == _epoch && isCurrent())
                .catchError((Object _) => false));
          }
        }
      }
      notifyListeners();
    } catch (error) {
      if (!_closed) {
        if (!isCurrent() ||
            (error is SafetyPollingException && error.terminal)) {
          _invalidate();
          return;
        }
        _stop();
        message = null;
        _cursor = null;
        // Keep the session generation pinned across transport failures.
        const delays = [2, 4, 8, 16, 30];
        final delay = delays[_failures.clamp(0, delays.length - 1)];
        _failures++;
        _retry?.cancel();
        _retry = Timer(Duration(seconds: delay), () {
          unawaited(poll());
        });
        status = error is SafetyPollingException && error.blocked
            ? 'BLOCKED · 이전 전송 종료 대기'
            : 'DEGRADED · 연결 재시도 대기';
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _retry?.cancel();
    cancelFetch?.call();
    _authSubscription?.cancel();
    _stop();
    priority.removeListener(_priorityChanged);
    super.dispose();
  }
}
