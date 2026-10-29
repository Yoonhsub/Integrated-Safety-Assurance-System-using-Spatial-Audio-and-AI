import 'dart:async';
import 'package:flutter/foundation.dart';
import 'speech_priority_coordinator.dart';
import 'session_guidance_audio.dart';

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
      this.audio,
      this.monotonicMicros,
      this.trace})
      : _allowSynthetic = allowSynthetic {
    if (audio != null && !identical(audio!.priority, priority)) {
      throw ArgumentError('Audio coordinator mismatch');
    }
    if (allowSynthetic && kReleaseMode) {
      throw StateError('Synthetic guidance is test/debug only');
    }
    _authSubscription = authChanges?.listen((_) {
      if (!isCurrent() && !_closed) _invalidate(reason: 'AUTH_EPOCH_CHANGED');
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
  final SessionGuidanceAudio? audio;
  final int Function()? monotonicMicros;
  final _clock = Stopwatch()..start();
  int _now() => monotonicMicros?.call() ?? _clock.elapsedMicroseconds;
  ObservationAdmission? _admission;
  final _seenEvents = <String>{};
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
      if (priority.outputUncertain) _admission?.mark('AUDIO_QUARANTINED');
      _stop(priority.outputUncertain ? 'AUDIO_QUARANTINED' : 'HIGHER_PRIORITY');
      notifyListeners();
    }
  }

  void setEnabled(bool value) {
    enabled = value;
    if (!value) _stop('STOP');
    notifyListeners();
  }

  void _stop([String reason = 'SUPERSEDED']) {
    _admission?.cancel(reason);
    _admission = null;
    message = null;
    _epoch++;
    _expiry?.cancel();
    unawaited(priority.stopObservation(_audioOwner).catchError((Object error) {
      trace?.call('AUDIO_STOP_FAILURE ${error.runtimeType}');
      debugPrint('Session Guidance stop failure: ${error.runtimeType}');
    }));
  }

  void close({bool notify = true}) {
    if (!_closed) _invalidate(notify: notify);
  }

  void _invalidate({bool notify = true, String reason = 'SESSION_CLOSED'}) {
    _closed = true;
    enabled = false;
    _timer?.cancel();
    _retry?.cancel();
    cancelFetch?.call();
    _stop(reason);
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
    final requestStarted = _now();
    try {
      final data = await fetch(sessionId, _cursor, _generation);
      final received = _now();
      if (received < requestStarted) {
        throw StateError('Invalid monotonic clock');
      }
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
        _invalidate(reason: 'SESSION_GENERATION_CHANGED');
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
        audio?.onScope?.call(sessionId, gen);
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
        final id = raw['eventId'] as String;
        if (!_seenEvents.add(id)) continue;
        if (_seenEvents.length > 128) _seenEvents.remove(_seenEvents.first);
        final ttl = raw['validForSeconds'];
        if (ttl is! num || !ttl.isFinite || ttl <= 0 || ttl > 3) continue;
        latest = raw;
      }
      if (latest != null && latest['message'] != _spokenMeaning) {
        final ttl = (latest['validForSeconds'] as num).toDouble() -
            (received - requestStarted) / 1000000;
        if (ttl > 0) {
          _stop();
          message = latest['message'] as String;
          final epoch = _epoch;
          final selected = audio ?? SessionGuidanceAudio(priority: priority);
          final admission = ObservationAdmission(
              deadlineMicros: received + (ttl * 1000000).floor(),
              nowMicros: _now,
              eventId: latest['eventId'] as String,
              sessionGeneration: gen,
              eventCreatedAt:
                  latest['timestamp'] is String ? latest['timestamp'] : null,
              receivedAt: DateTime.now().toUtc().toIso8601String(),
              authEpoch: selected.authEpochSnapshot,
              trace: selected.trace);
          admission.mark('receivedAt');
          _admission = admission;
          _expiry = Timer(Duration(microseconds: (ttl * 1000000).floor()), () {
            admission.expired();
            // Expire display/admission only. A started info job owns its playback
            // until normal completion, lifecycle invalidation or the30s watchdog.
            message = null;
            notifyListeners();
          });
          if (enabled &&
              !priority.priorityActive &&
              _spokenMeaning != message) {
            _spokenMeaning = message;
            unawaited(_deliver(
                selected,
                admission,
                SessionGuidanceObservation(
                    sessionId: sessionId,
                    ownerUid: ownerUid,
                    generation: gen,
                    eventId: latest['eventId'] as String,
                    text: message!,
                    synthetic: latest['synthetic'] as bool),
                epoch));
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
        _stop('POLL_FAILURE');
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

  Future<void> _deliver(
      SessionGuidanceAudio output,
      ObservationAdmission admission,
      SessionGuidanceObservation observation,
      int epoch) async {
    try {
      await output.speak(_audioOwner, observation,
          () => !_closed && enabled && epoch == _epoch && isCurrent(),
          admission: admission);
    } catch (error) {
      admission.mark('AUDIO_FAILURE_${error.runtimeType}');
      admission.cancel(error is SpeechPlaybackTimeout
          ? 'PLAYBACK_WATCHDOG'
          : error is SpeechCancelled
              ? 'CANCELLED'
              : 'ENGINE_OR_STOP_FAILURE');
      trace?.call('AUDIO_FAILURE ${error.runtimeType}');
      debugPrint('Session Guidance audio failure: ${error.runtimeType}');
    } finally {
      if (identical(_admission, admission)) _admission = null;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _retry?.cancel();
    cancelFetch?.call();
    _authSubscription?.cancel();
    _stop('DISPOSE');
    priority.removeListener(_priorityChanged);
    super.dispose();
  }
}
