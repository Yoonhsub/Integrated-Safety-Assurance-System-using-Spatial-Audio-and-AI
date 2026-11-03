import 'dart:async';
import 'package:flutter/foundation.dart';
import 'directional_guidance.dart';
import 'spatial_verification_engine.dart';
import 'speech_priority_coordinator.dart';

/// Only constructed after the receiver has checked ownership, cursor and TTL.
class SessionGuidanceObservation {
  const SessionGuidanceObservation(
      {required this.sessionId,
      required this.ownerUid,
      required this.generation,
      required this.eventId,
      required this.text,
      required this.synthetic});
  final String sessionId, ownerUid, generation, eventId, text;
  final bool synthetic;
}

/// Explicit debug receipt, held outside the Backend event schema. A field in an
/// event is never direction evidence. All scope fields must match at consumption.
class LocalDirectionReceipt {
  const LocalDirectionReceipt(
      {required this.sessionId,
      required this.ownerUid,
      required this.generation,
      required this.authEpoch,
      required this.eventId,
      required this.createdAt,
      required this.direction,
      this.coordinateFrame = 'listener-relative-rightX-upY-forwardMinusZ'});
  final String sessionId, ownerUid, generation, eventId, coordinateFrame;
  final int authEpoch;
  final DateTime createdAt;
  final TestDirection direction;
}

/// One observation admission receipt, not a second audio controller. Freshness
/// gates the first audible request only; lifecycle cancellation always remains.
class ObservationAdmission {
  ObservationAdmission(
      {required this.deadlineMicros,
      required this.nowMicros,
      required this.eventId,
      required this.sessionGeneration,
      required this.receivedAt,
      this.eventCreatedAt,
      this.authEpoch,
      this.trace});
  final int deadlineMicros;
  final int Function() nowMicros;
  final String eventId, sessionGeneration, receivedAt;
  final Object? eventCreatedAt;
  final int? authEpoch;
  final void Function(Map<String, Object?>)? trace;
  bool started = false, _ended = false, _tts = false;
  final _times = <String, int>{};
  String? cancelReason;
  int traceFailures = 0;
  void mark(String phase) {
    final at = nowMicros();
    const names = {
      'freshnessCheckedAt': 'freshnessCheckedAt',
      'CUE_START': 'cueStartedAt',
      'CUE_COMPLETED': 'cueCompletedAt',
      'TTS_START': 'ttsStartedAt',
      'TTS_COMPLETED': 'ttsCompletedAt',
      'ttsCompletedAt': 'ttsCompletedAt',
      'ttsCancelledAt': 'ttsCancelledAt'
    };
    if (names.containsKey(phase)) _times[names[phase]!] = at;
    final record = <String, Object?>{
      ..._times,
      'eventId': eventId,
      'sessionGeneration': sessionGeneration,
      'authEpoch': authEpoch,
      'eventCreatedAt': eventCreatedAt,
      'receivedAt': receivedAt,
      'phase': phase,
      'monotonicMicros': at,
      'freshnessDeadlineMicros': deadlineMicros,
      'activeAudioLease': started && !_ended ? 'observation:$eventId' : null,
      'cancelReason': cancelReason
    };
    try {
      trace?.call(record);
    } catch (error) {
      // Logging is not an audio control dependency. Preserve cancellation and
      // surface this diagnostic failure independently of engine/cleanup errors.
      traceFailures++;
      debugPrint('Observation trace sink failure: ${error.runtimeType}');
    }
  }

  Duration get remainingFreshness {
    final remaining = deadlineMicros - nowMicros();
    return Duration(microseconds: remaining > 0 ? remaining : 0);
  }

  bool admit() {
    if (_ended || cancelReason != null) return false;
    if (started) return true;
    mark('freshnessCheckedAt');
    if (nowMicros() >= deadlineMicros) {
      cancelReason = 'EVENT_EXPIRED_BEFORE_START';
      _ended = true;
      mark('ADMISSION_REJECTED');
      return false;
    }
    started = true;
    mark('PLAYBACK_ADMITTED');
    return true;
  }

  void phase(String phase) {
    if (_ended) return;
    if (phase == 'TTS_START') _tts = true;
    mark(phase);
  }

  void expired() => mark(started && !_ended
      ? 'EVENT_FRESHNESS_EXPIRED_PLAYBACK_CONTINUES'
      : 'EVENT_FRESHNESS_EXPIRED');
  void cancel(String reason) {
    if (_ended) return;
    cancelReason = reason;
    _ended = true;
    mark(_tts ? 'ttsCancelledAt' : 'PLAYBACK_CANCELLED');
  }

  void finish(bool completed) {
    if (_ended) return;
    if (!completed) {
      cancel('CANCELLED_OR_NOT_ADMITTED');
      return;
    }
    _ended = true;
    mark(_tts ? 'ttsCompletedAt' : 'PLAYBACK_COMPLETED');
  }
}

class SessionGuidanceAudio {
  SessionGuidanceAudio(
      {required this.priority, this.diagnostic, this.trace, this.onScope});
  SessionGuidanceAudio.localVerification(
      {required this.priority,
      required SpatialVerificationEngine engine,
      required int Function() authEpoch,
      required LocalDirectionReceipt? Function(String) receipt,
      Future<void> Function()? waitForLocalBinding,
      DateTime Function()? clock,
      this.diagnostic,
      this.trace,
      this.onScope})
      : _engine = engine,
        _authEpoch = authEpoch,
        _receipt = receipt,
        _waitForLocalBinding = waitForLocalBinding,
        _clock = clock ?? DateTime.now {
    if (!kDebugMode) throw StateError('Local directions require debug mode');
  }
  final SpeechPriorityCoordinator priority;
  final void Function(String)? diagnostic;
  final void Function(Map<String, Object?>)? trace;
  final void Function(String sessionId, String generation)? onScope;
  int? get authEpochSnapshot => _authEpoch?.call();
  SpatialVerificationEngine? _engine;
  int Function()? _authEpoch;
  LocalDirectionReceipt? Function(String)? _receipt;
  DateTime Function()? _clock;
  Future<void> Function()? _waitForLocalBinding;

  Future<bool> speak(Object owner, SessionGuidanceObservation observation,
      bool Function() isCurrent,
      {ObservationAdmission? admission}) async {
    if (!isCurrent() || priority.priorityActive) return false;
    // Never allow wire text to address the local engine's reserved commands.
    if (observation.text.trim().isEmpty || observation.text.startsWith('@')) {
      diagnostic?.call('AUDIO_TEXT_REJECTED');
      return false;
    }
    final requestEpoch = _authEpoch?.call();
    if (_waitForLocalBinding != null) {
      if (admission == null) {
        throw StateError('Admission required for local binding');
      }
      final remaining = admission.remainingFreshness;
      if (remaining <= Duration.zero) {
        admission.cancel('EVENT_EXPIRED_BEFORE_START');
        return false;
      }
      admission.mark('LOCAL_BINDING_WAIT');
      try {
        await _waitForLocalBinding!().timeout(remaining);
      } on TimeoutException {
        admission.cancel('LOCAL_BINDING_FRESHNESS_EXPIRED');
        return false;
      }
      if (!isCurrent() ||
          priority.priorityActive ||
          requestEpoch != _authEpoch?.call()) {
        admission.cancel('LOCAL_BINDING_SCOPE_CHANGED');
        return false;
      }
    }
    final receipt = _receipt?.call(observation.eventId);
    if (_engine == null) {
      final result = await priority.speakObservation(
          owner, observation.text, isCurrent,
          admit: admission?.admit,
          onStarted: () => admission?.phase('TTS_START'),
          onDeadline: () => admission?.cancel('PLAYBACK_WATCHDOG'));
      admission?.finish(result);
      return result;
    }
    final epoch = _authEpoch!();
    final age = receipt == null
        ? Duration.zero
        : _clock!().difference(receipt.createdAt);
    if (receipt != null &&
        (!kDebugMode ||
            !observation.synthetic ||
            receipt.sessionId != observation.sessionId ||
            receipt.ownerUid != observation.ownerUid ||
            receipt.generation != observation.generation ||
            receipt.eventId != observation.eventId ||
            receipt.authEpoch != epoch ||
            receipt.coordinateFrame !=
                'listener-relative-rightX-upY-forwardMinusZ' ||
            age.isNegative ||
            age > const Duration(seconds: 3))) {
      diagnostic?.call('DIRECTION_SCOPE_REJECTED');
      admission?.cancel('DIRECTION_SCOPE_REJECTED');
      return false; // A bad explicit receipt is not permission for fallback audio.
    }
    bool current() =>
        isCurrent() && epoch == _authEpoch!() && !priority.priorityActive;
    final guidance = DirectionalGuidance(
        guidanceId: observation.eventId,
        sessionGeneration: observation.generation,
        authEpoch: epoch,
        priority: GuidancePriority.observation,
        text: observation.text,
        provenance: DirectionalGuidance.syntheticProvenance,
        testDirection: receipt?.direction,
        directionEvidence: DirectionEvidence.explicitLocalFixture);
    final command = _engine!.registerGuidance(guidance, current,
        admit: admission?.admit,
        phase: admission?.phase,
        spokenText: observation.text);
    if (command == null) return false;
    try {
      final result = await priority.speakObservation(owner, command, current,
          onDeadline: () => admission?.cancel('PLAYBACK_WATCHDOG'));
      admission?.finish(result);
      return result;
    } finally {
      _engine!.retireGuidance(command);
    }
  }
}
