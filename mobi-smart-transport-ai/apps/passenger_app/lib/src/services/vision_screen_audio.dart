import 'dart:async';
import 'package:flutter/foundation.dart';
import 'directional_guidance.dart';
import 'session_guidance_audio.dart';
import 'spatial_verification_engine.dart';
import 'speech_priority_coordinator.dart';

/// Camera-only information adapter. No SafetyInterpreter, Backend write,
/// guidanceEligible change, object tracking, distance or world direction.
class VisionScreenAudio extends ChangeNotifier {
  VisionScreenAudio(
      {required this.priority,
      required this.engine,
      required this.sessionGeneration,
      required this.isCurrent,
      int Function()? nowMicros,
      this.minimumInterval = const Duration(seconds: 8)})
      : _now = nowMicros ?? (() => _clock.elapsedMicroseconds) {
    if (!identical(priority.engine, engine)) {
      throw ArgumentError('Audio owner mismatch');
    }
    priority.addListener(_priorityChanged);
  }
  static final _clock = Stopwatch()..start();
  final SpeechPriorityCoordinator priority;
  final SpatialVerificationEngine engine;
  final String sessionGeneration;
  final bool Function() isCurrent;
  final Duration minimumInterval;
  final int Function() _now;
  final _owner = Object();
  bool enabled = false, busy = false, _disposed = false;
  int _revision = 0, admitted = 0, completed = 0, skippedBusy = 0;
  String status = '카메라 화면 음향 시연 OFF';
  String? _lastFrame, _lastMeaning;
  int? _lastStarted;
  PriorityLease? _hold;
  Map<String, Object?> diagnostic = const {};
  bool get holding => _hold != null;
  static const classNames = {
    'bus': '버스',
    'bus_door': '버스 문',
    'bus_stop': '버스 정류장',
    'roadway': '차도',
    'sidewalk': '보도',
    'obstacle': '장애물',
    'tactile_paving': '점자블록'
  };
  static TestDirection direction(double centerX) => centerX < 1 / 3
      ? TestDirection.left
      : centerX > 2 / 3
          ? TestDirection.right
          : TestDirection.center;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setEnabled(bool value) {
    if (_disposed) return;
    if (!value) {
      unawaited(stop());
      return;
    }
    if (!isCurrent() || priority.outputUncertain) {
      status = '음향 시연 차단 · 세션 또는 오디오 종료 상태를 확인해 주세요';
      _notify();
      return;
    }
    enabled = true;
    _lastMeaning = null;
    status = '화면 기준 음향 시연 ON · 새 검출 대기';
    _notify();
  }

  void _priorityChanged() {
    if (priority.priorityActive && !_disposed) {
      _revision++;
      status = priority.outputUncertain
          ? '오디오 종료 미확인 · 새 재생 차단'
          : 'Live Hold / 기존 안내 우선 · 이전 요청 폐기';
      unawaited(_stopOwned());
      _notify();
    }
  }

  Future<void> _stopOwned() async {
    try {
      await priority.stopObservation(_owner);
    } catch (error) {
      debugPrint('Camera screen audio stop failure: ${error.runtimeType}');
      if (!_disposed) {
        enabled = false;
        status = '음향 중단 확인 실패 · 앱을 다시 열어 주세요';
        _notify();
      }
    }
  }

  Future<void> stop({bool notify = true}) {
    enabled = false;
    _revision++;
    _hold?.release();
    _hold = null;
    status = '화면 음향 시연 STOP · 후속 TTS 없음';
    if (notify) _notify();
    return _stopOwned();
  }

  Future<void> toggleHold() async {
    if (_disposed || !isCurrent()) return;
    if (_hold != null) {
      _hold!.release();
      _hold = null;
      status = 'Hold 해제 · 새 검출만 허용';
      _notify();
      return;
    }
    _hold = priority.claimPriority();
    _revision++;
    await _stopOwned();
    _notify();
  }

  void observe(Map<String, Object?> result, {required Duration age}) {
    if (_disposed || !enabled || !isCurrent()) return;
    if (result['status'] != 'ok') {
      unawaited(stop());
      return;
    }
    if (age.isNegative ||
        age >= const Duration(seconds: 2) ||
        result['source'] != 'android_camera' ||
        result['frameId'] is! String ||
        result['frameId'] == _lastFrame) {
      return;
    }
    _lastFrame = result['frameId'] as String;
    if (busy || priority.priorityActive) {
      skippedBusy++;
      return;
    }
    final size = result['imageSize'], rows = result['detections'];
    if (size is! Map ||
        size['width'] is! int ||
        size['height'] is! int ||
        size['width'] <= 0 ||
        size['height'] <= 0 ||
        rows is! List) {
      return;
    }
    Map? selected;
    double best = -1;
    for (final row in rows) {
      if (row is! Map ||
          !classNames.containsKey(row['classId']) ||
          classNames[row['classId']] != row['className']) {
        continue;
      }
      final c = row['confidence'], b = row['bbox'];
      if (c is! num ||
          !c.isFinite ||
          c < .5 ||
          c > 1 ||
          b is! Map ||
          ['x', 'y', 'w', 'h']
              .any((k) => b[k] is! num || !(b[k] as num).isFinite)) {
        continue;
      }
      final x = b['x'] as num,
          y = b['y'] as num,
          w = b['w'] as num,
          h = b['h'] as num;
      if (x < 0 ||
          y < 0 ||
          w <= 0 ||
          h <= 0 ||
          x + w > 1.000000001 ||
          y + h > 1.000000001) {
        continue;
      }
      if (c > best) {
        selected = row;
        best = c.toDouble();
      }
    }
    if (selected == null) {
      if (rows.isEmpty) _lastMeaning = null;
      return;
    }
    final box = selected['bbox'] as Map;
    final cx = (box['x'] as num).toDouble() + (box['w'] as num).toDouble() / 2;
    final side = direction(cx),
        meaning = '${selected['classId']}:${direction(cx).name}';
    if (_lastMeaning == meaning ||
        (_lastStarted != null &&
            _now() - _lastStarted! < minimumInterval.inMicroseconds)) {
      return;
    }
    final sideText = switch (side) {
      TestDirection.left => '왼쪽',
      TestDirection.center => '가운데',
      TestDirection.right => '오른쪽'
    };
    final text =
        '화면 위치 시연입니다. 화면 $sideText, 인식된 객체 이름은 ${selected['className']}입니다. 실제 거리와 이동 방향은 알 수 없습니다.';
    final revision = _revision;
    bool valid() =>
        !_disposed &&
        enabled &&
        revision == _revision &&
        isCurrent() &&
        !priority.priorityActive;
    final admission = ObservationAdmission(
        deadlineMicros: _now() +
            const Duration(seconds: 2).inMicroseconds -
            age.inMicroseconds,
        nowMicros: _now,
        eventId: result['frameId'] as String,
        sessionGeneration: sessionGeneration,
        receivedAt: DateTime.now().toUtc().toIso8601String(),
        eventCreatedAt: result['capturedAt']);
    bool admit() {
      final already = admission.started;
      if (!admission.admit()) return false;
      if (!already) {
        _lastMeaning = meaning;
        _lastStarted = _now();
        admitted++;
      }
      return true;
    }

    final guidance = DirectionalGuidance(
        guidanceId: result['frameId'] as String,
        sessionGeneration: sessionGeneration,
        // The real auth lifetime is the caller's pinned request guard, not this
        // legacy local-verification integer namespace.
        authEpoch: 0,
        priority: GuidancePriority.observation,
        text: text,
        provenance: DirectionalGuidance.screenProvenance,
        testDirection: side,
        directionEvidence: DirectionEvidence.cameraScreenBbox);
    final command = engine.registerGuidance(guidance, valid,
        admit: admit, spokenText: text, phase: (phase) {
      if (valid()) {
        status = phase;
        diagnostic = {...diagnostic, 'phase': phase};
        _notify();
      }
    });
    if (command == null) return;
    diagnostic = {
      'frameId': result['frameId'],
      'capturedAt': result['capturedAt'],
      'classId': selected['classId'],
      'className': selected['className'],
      'confidence': best,
      'bbox': Map<String, Object?>.from(box),
      'screenCenterX': cx,
      'screenDirection': side.name.toUpperCase(),
      'coordinateFrame': 'upright-mirrored-camera-image',
      'provenance': DirectionalGuidance.screenProvenance,
      'guidanceEligible': false,
      'text': text
    };
    busy = true;
    status = 'Cue → TTS 준비';
    _notify();
    unawaited(() async {
      try {
        final ok = await priority.speakObservation(_owner, command, valid,
            onDeadline: () => admission.cancel('PLAYBACK_WATCHDOG'));
        admission.finish(ok);
        if (ok) completed++;
        if (revision == _revision && !_disposed) {
          status = ok ? 'Cue → 문장 완료' : '취소 또는 시작 전 만료 · 새 검출 대기';
        }
      } catch (error) {
        admission.cancel('AUDIO_FAILURE');
        debugPrint('Camera screen audio failure: ${error.runtimeType}');
        if (!_disposed && revision == _revision) {
          if (error is SpeechCancelled && !priority.outputUncertain) {
            status = '시작 전 만료 또는 취소 · 새 검출 대기';
          } else {
            enabled = false;
            status = '음향 시연 오류 · 출력 상태를 확인해 주세요';
          }
        }
      } finally {
        engine.retireGuidance(command);
        busy = false;
        _notify();
      }
    }());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    enabled = false;
    _revision++;
    priority.removeListener(_priorityChanged);
    _hold?.release();
    _hold = null;
    unawaited(_stopOwned());
    super.dispose();
  }
}
