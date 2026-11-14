import 'dart:async';
import 'vision_scene_summary.dart';
import 'package:flutter/foundation.dart';
import 'directional_guidance.dart';
import 'session_guidance_audio.dart';
import 'spatial_verification_engine.dart';
import 'speech_priority_coordinator.dart';
import 'head_tracking_direction.dart';

/// Camera-only information adapter. No SafetyInterpreter, Backend write,
/// guidanceEligible change, object tracking, distance or world direction.
class VisionScreenAudio extends ChangeNotifier {
  VisionScreenAudio({
    required this.priority,
    required this.engine,
    required this.sessionGeneration,
    required this.isCurrent,
    HeadTrackingState? headTracking,
    double? horizontalFovDegrees,
    int Function()? nowMicros,
    this.minimumInterval = const Duration(seconds: 8),
    this.confirmationFrames = 1,
    this.requireDoorInBus = false,
    this.prioritizeByDistance = false,
    this.sceneMode = false,
    this.pingOnly = false,
  })  : headTracking = headTracking ?? sharedHeadTrackingState,
        horizontalFovDegrees = horizontalFovDegrees ?? _configuredFov,
        _now = nowMicros ?? (() => _clock.elapsedMicroseconds) {
    if (!identical(priority.engine, engine)) {
      throw ArgumentError('Audio owner mismatch');
    }
    if (confirmationFrames < 1) {
      throw ArgumentError('confirmationFrames must be >= 1');
    }
    _sceneTracker =
        VisionSceneSummaryTracker(confirmationFrames: confirmationFrames);
    this.headTracking.resetForSession();
    priority.addListener(_priorityChanged);
    this.headTracking.addListener(_headTrackingChanged);
  }
  static final _clock = Stopwatch()..start();
  static final double _configuredFov = double.tryParse(
        const String.fromEnvironment('MOBI_CAMERA_HORIZONTAL_FOV_DEGREES'),
      ) ??
      0;
  static const double minDoorInBusOverlap = 0.70;
  final SpeechPriorityCoordinator priority;
  final SpatialVerificationEngine engine;
  final String sessionGeneration;
  final bool Function() isCurrent;
  final Duration minimumInterval;
  final int confirmationFrames;
  final bool requireDoorInBus;
  final bool prioritizeByDistance;
  final bool sceneMode, pingOnly;
  late final VisionSceneSummaryTracker _sceneTracker;
  Timer? _sceneTimer;
  DateTime? lastSceneReceivedAt;
  Map<String, Object?> sceneOutputDiagnostic = const {};
  String? _sceneMeaning;
  int _sceneSequence = 0;
  VisionSceneSummary get scene =>
      _sceneTracker.snapshot(DateTime.now().toUtc());
  bool get canDescribeScene =>
      !busy &&
      isCurrent() &&
      !priority.priorityActive &&
      scene.isFresh(DateTime.now().toUtc());
  final HeadTrackingState headTracking;
  final double horizontalFovDegrees;
  final int Function() _now;
  final _owner = Object();
  HeadTrackingMountCalibration mountCalibration =
      const HeadTrackingMountCalibration();
  bool enabled = false,
      headTrackingEnabled = false,
      busy = false,
      _activeHeadTracked = false,
      _disposed = false;
  int _revision = 0, admitted = 0, completed = 0, skippedBusy = 0;
  int _streakCount = 0;
  String status = '카메라 화면 음향 시연 OFF';
  String? _lastFrame, _lastMeaning, _streakMeaning;
  int? _lastStarted;
  PriorityLease? _hold;
  Map<String, Object?> diagnostic = const {};
  bool get holding => _hold != null;
  HeadTrackingSnapshot get headTrackingSnapshot => headTracking.snapshot;
  bool get hasCameraCalibration =>
      horizontalFovDegrees > 0 &&
      horizontalFovDegrees < 180 &&
      horizontalFovDegrees.isFinite;
  bool get canActivateHeadTracking =>
      hasCameraCalibration &&
      mountCalibration.verified &&
      mountCalibration.mount != HeadTrackingCameraMount.handheldPhone &&
      isCurrent() &&
      !priority.priorityActive &&
      !priority.outputUncertain &&
      headTracking.snapshot.usable(DateTime.now().toUtc());

  bool _preempting = false;
  static bool _isObstacle(Object? id) =>
      id == 'parked_pm' || id == 'pole' || id == 'tree_trunk';

  static const classNames = {
    'bus': '버스',
    'bus_door': '버스 문',
    'bus_stop': '버스 정류장',
    'parked_pm': '방치 전동 킥보드',
    'pole': '보도 기둥',
    'tree_trunk': '나무 줄기',
    'roadway': '차도',
    'sidewalk': '보도',
    'tactile_paving': '점자블록',
  };
  static const _classPriority = <String, int>{
    'parked_pm': 0,
    'pole': 1,
    'tree_trunk': 2,
    'bus_door': 3,
    'bus': 4,
    'bus_stop': 5,
  };
  static TestDirection direction(double centerX) => centerX < 1 / 3
      ? TestDirection.left
      : centerX > 2 / 3
          ? TestDirection.right
          : TestDirection.center;

  /// Relative distance rank based on normalized bbox area and vertical ground
  /// position (bottomY = y + h). Returns 0 for NEAR, 1 for MEDIUM, 2 for FAR.
  static int distanceRank(String classId, Map b) {
    final w = (b['w'] as num).toDouble(),
        h = (b['h'] as num).toDouble(),
        y = (b['y'] as num).toDouble();
    final area = w * h, bottomY = y + h;
    if (classId == 'bus_door') {
      if (area >= 0.06 || bottomY >= 0.85) return 0;
      if (area >= 0.015 || bottomY >= 0.65) return 1;
      return 2;
    }
    if (classId == 'parked_pm' ||
        classId == 'pole' ||
        classId == 'tree_trunk') {
      if (area >= 0.08 || bottomY >= 0.80) return 0;
      if (area >= 0.02 || bottomY >= 0.60) return 1;
      return 2;
    }
    if (area >= 0.25 || bottomY >= 0.85) return 0;
    if (area >= 0.08 || bottomY >= 0.65) return 1;
    return 2;
  }

  static double proximityScore(Map b) {
    final w = (b['w'] as num).toDouble(),
        h = (b['h'] as num).toDouble(),
        y = (b['y'] as num).toDouble();
    return (y + h) * 0.6 + (w * h) * 0.4;
  }

  static bool _isValidBoxMap(Map b) {
    if ([
      'x',
      'y',
      'w',
      'h',
    ].any((k) => b[k] is! num || !(b[k] as num).isFinite)) {
      return false;
    }
    final x = b['x'] as num,
        y = b['y'] as num,
        w = b['w'] as num,
        h = b['h'] as num;
    return x >= 0 &&
        y >= 0 &&
        w > 0 &&
        h > 0 &&
        x + w <= 1.000000001 &&
        y + h <= 1.000000001;
  }

  /// The same strict parent-bus condition is shared with diagnostic previews.
  /// Unverified doors are omitted, never used to suppress a valid obstacle.
  static List<dynamic> verifiedDoorDetections(List<dynamic> rows) => rows
      .where((row) =>
          row is! Map ||
          row['classId'] != 'bus_door' ||
          (row['bbox'] is Map &&
              _isValidBoxMap(row['bbox'] as Map) &&
              _parentBusBox(row['bbox'] as Map, rows) != null))
      .toList(growable: false);

  /// Returns the bbox of the parent `bus` containing at least [minDoorInBusOverlap]
  /// of [doorBox], preferring largest intersection area then largest bus area.
  static Map? _parentBusBox(Map doorBox, List rows) {
    final dx1 = (doorBox['x'] as num).toDouble();
    final dy1 = (doorBox['y'] as num).toDouble();
    final dw = (doorBox['w'] as num).toDouble();
    final dh = (doorBox['h'] as num).toDouble();
    final doorArea = dw * dh;
    if (doorArea <= 0) return null;
    final dx2 = dx1 + dw, dy2 = dy1 + dh;
    Map? bestBus;
    double bestInterArea = -1;
    double bestBusArea = -1;
    for (final row in rows) {
      if (row is! Map || row['classId'] != 'bus' || row['className'] != '버스') {
        continue;
      }
      final c = row['confidence'], b = row['bbox'];
      if (c is! num ||
          !c.isFinite ||
          c < .5 ||
          c > 1 ||
          b is! Map ||
          !_isValidBoxMap(b)) {
        continue;
      }
      final bx1 = (b['x'] as num).toDouble();
      final by1 = (b['y'] as num).toDouble();
      final bw = (b['w'] as num).toDouble();
      final bh = (b['h'] as num).toDouble();
      final bx2 = bx1 + bw, by2 = by1 + bh;
      final ix1 = dx1 > bx1 ? dx1 : bx1;
      final iy1 = dy1 > by1 ? dy1 : by1;
      final ix2 = dx2 < bx2 ? dx2 : bx2;
      final iy2 = dy2 < by2 ? dy2 : by2;
      if (ix2 > ix1 && iy2 > iy1) {
        final interArea = (ix2 - ix1) * (iy2 - iy1);
        final busArea = bw * bh;
        if (interArea / doorArea >= minDoorInBusOverlap &&
            (interArea > bestInterArea ||
                (interArea == bestInterArea && busArea > bestBusArea))) {
          bestBus = b;
          bestInterArea = interArea;
          bestBusArea = busArea;
        }
      }
    }
    return bestBus;
  }

  ({
    Map? selected,
    double bestConfidence,
    int bestRank,
  }) _analyzeFrame(List rows) {
    Map? selected;
    double best = -1;
    int bestRank = 99;
    int bestPriority = 99;
    double bestProximity = -1;
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
          !_isValidBoxMap(b)) {
        continue;
      }
      final classId = row['classId'] as String;
      final Map? parentBus =
          classId == 'bus_door' ? _parentBusBox(b, rows) : null;
      if (classId == 'bus_door' && requireDoorInBus && parentBus == null) {
        continue;
      }
      // Inherit distance rank from parent bus so a narrow door on a near bus
      // is not outranked by its own bus body (matches Python spatial_guidance.py).
      final int effectiveRank = parentBus != null
          ? distanceRank('bus', parentBus)
          : distanceRank(classId, b);
      if (prioritizeByDistance) {
        final prio = _classPriority[classId] ?? 99;
        final prox = proximityScore(b);
        final better = selected == null ||
            effectiveRank < bestRank ||
            (effectiveRank == bestRank && prio < bestPriority) ||
            (effectiveRank == bestRank &&
                prio == bestPriority &&
                prox > bestProximity) ||
            (effectiveRank == bestRank &&
                prio == bestPriority &&
                prox == bestProximity &&
                c > best);
        if (better) {
          selected = row;
          best = c.toDouble();
          bestRank = effectiveRank;
          bestPriority = prio;
          bestProximity = prox;
        }
      } else if (c > best) {
        selected = row;
        best = c.toDouble();
      }
    }
    return (
      selected: selected,
      bestConfidence: best,
      bestRank: bestRank,
    );
  }

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
    _streakMeaning = null;
    _streakCount = 0;
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

  void _headTrackingChanged() {
    if (_disposed) return;
    if (headTrackingEnabled &&
        !headTracking.snapshot.usable(DateTime.now().toUtc())) {
      _invalidateHeadTracking('센서 연결 또는 최신 보정 yaw 무효');
    }
    _notify();
  }

  void _invalidateHeadTracking(String reason) {
    final mustStop = headTrackingEnabled && _activeHeadTracked;
    headTrackingEnabled = false;
    if (mustStop) {
      _revision++;
      unawaited(_stopOwned());
    }
    status = '$reason · 새 프레임부터 기존 화면 기준 Cue 사용';
  }

  void setHeadTrackingMount(HeadTrackingCameraMount mount) {
    if (_disposed) return;
    _invalidateHeadTracking('장착 방식 변경');
    mountCalibration = HeadTrackingMountCalibration(mount: mount);
    _notify();
  }

  void setMountAlignment({
    required bool verified,
    double? cameraAxisOffsetDegrees,
  }) {
    if (_disposed) return;
    _invalidateHeadTracking('축 정렬 확인 변경');
    mountCalibration = HeadTrackingMountCalibration(
      mount: mountCalibration.mount,
      axesAlignmentVerified: verified,
      cameraAxisOffsetDegrees: verified &&
              cameraAxisOffsetDegrees?.isFinite == true &&
              cameraAxisOffsetDegrees!.abs() <= 180
          ? cameraAxisOffsetDegrees
          : null,
    );
    _notify();
  }

  void setHeadTrackingEnabled(bool value) {
    if (_disposed) return;
    if (!value) {
      headTrackingEnabled = false;
      status = 'Head Tracking OFF · 기존 화면 기준 Cue 사용';
      _notify();
      return;
    }
    if (!canActivateHeadTracking) {
      headTrackingEnabled = false;
      status = !hasCameraCalibration
          ? '카메라 수평 화각 미확인 · Head Tracking 사용 불가'
          : !mountCalibration.supportsHeadTrackedCue
              ? '지원·검증된 카메라 장착 방식이 아님 · 화면 기준 Cue 유지'
              : !mountCalibration.verified
                  ? '카메라·센서 축 정렬과 측정 오프셋 확인 필요'
                  : '활성 세션·오디오 소유권·READY 센서 확인 필요';
      _notify();
      return;
    }
    headTrackingEnabled = true;
    status = 'Head Tracking ON · HRTF 핑만 보정, TTS는 일반 출력';
    _notify();
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
    _sceneTimer?.cancel();
    _sceneTracker.invalidate(reason: 'stopped');
    _sceneMeaning = null;
    enabled = false;
    _revision++;
    _streakMeaning = null;
    _streakCount = 0;
    _hold?.release();
    _hold = null;
    sceneOutputDiagnostic = {
      ...sceneOutputDiagnostic,
      'phase': 'STOP_REQUESTED'
    };
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

  void observe(Map<String, Object?> result,
      {required Duration age,
      DateTime? receivedAt,
      double? inferenceMs,
      double? processingMs}) {
    if (_disposed || !isCurrent()) return;
    if (sceneMode || pingOnly) {
      _observeScene(result,
          age: age,
          receivedAt: receivedAt,
          inferenceMs: inferenceMs,
          processingMs: processingMs);
      return;
    }
    if (!enabled) return;
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
    if (priority.priorityActive) {
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
      if (busy) skippedBusy++;
      return;
    }
    final analysis = _analyzeFrame(rows);
    // Stop only our lower-priority preview output. Do not replay this frame
    // after cancellation: a new, fresh camera frame must confirm the obstacle.
    if (_preempting) return;
    if (busy) {
      if (_isObstacle(analysis.selected?['classId']) &&
          !_isObstacle(diagnostic['classId'])) {
        _preempting = true;
        _revision++;
        _lastMeaning = null;
        _lastStarted = null;
        _streakMeaning = null;
        _streakCount = 0;
        unawaited(_stopOwned().whenComplete(() => _preempting = false));
      }
      skippedBusy++;
      return;
    }
    final selected = analysis.selected;
    final best = analysis.bestConfidence;
    final bestRank = analysis.bestRank;

    if (selected == null) {
      _streakMeaning = null;
      _streakCount = 0;
      if (rows.isEmpty) _lastMeaning = null;
      return;
    }
    final box = selected['bbox'] as Map;
    final cx = (box['x'] as num).toDouble() + (box['w'] as num).toDouble() / 2;
    final side = direction(cx), meaning = '${selected['classId']}:${side.name}';
    if (_streakMeaning == meaning) {
      _streakCount++;
    } else {
      _streakMeaning = meaning;
      _streakCount = 1;
    }
    if (_streakCount < confirmationFrames) {
      return;
    }
    final replacesNonObstacle =
        _isObstacle(selected['classId']) && !_isObstacle(diagnostic['classId']);
    if (_lastMeaning == meaning ||
        (!replacesNonObstacle &&
            _lastStarted != null &&
            _now() - _lastStarted! < minimumInterval.inMicroseconds)) {
      return;
    }
    final sideText = switch (side) {
      TestDirection.left => '왼쪽',
      TestDirection.center => '가운데',
      TestDirection.right => '오른쪽',
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
      eventCreatedAt: result['capturedAt'],
    );
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

    double? cameraAngle, correctedAngle;
    if (headTrackingEnabled && canActivateHeadTracking) {
      cameraAngle = horizontalAngleForNormalizedBbox(
        x: (box['x'] as num).toDouble(),
        width: (box['w'] as num).toDouble(),
        horizontalFovDegrees: horizontalFovDegrees,
      );
      correctedAngle = headTrackedAngleForMount(
        cameraAngle: cameraAngle,
        sensor: headTracking.snapshot,
        now: DateTime.now().toUtc(),
        calibration: mountCalibration,
      );
      if (correctedAngle == null) {
        _invalidateHeadTracking('장착·센서 조건 무효');
      }
    } else if (headTrackingEnabled) {
      _invalidateHeadTracking('장착·센서 조건 무효');
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
      headTrackedAzimuthDegrees: correctedAngle,
      directionEvidence: DirectionEvidence.cameraScreenBbox,
    );
    final command = engine.registerGuidance(
      guidance,
      valid,
      admit: admit,
      spokenText: text,
      phase: (phase) {
        if (valid()) {
          status = phase;
          diagnostic = {...diagnostic, 'phase': phase};
          _notify();
        }
      },
    );
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
      if (prioritizeByDistance)
        'relativeDistance': switch (bestRank) {
          0 => 'NEAR',
          1 => 'MEDIUM',
          _ => 'FAR',
        },
      'headTrackingStatus': headTracking.snapshot.status.name,
      'headTrackingEnabled': correctedAngle != null,
      'headTrackingMount': mountCalibration.mount.name,
      'axesAlignmentVerified': mountCalibration.axesAlignmentVerified,
      if (cameraAngle != null) 'cameraAngleDegrees': cameraAngle,
      if (correctedAngle != null) 'correctedAngleDegrees': correctedAngle,
      'coordinateFrame': 'upright-mirrored-camera-image',
      'provenance': DirectionalGuidance.screenProvenance,
      'guidanceEligible': false,
      'text': text,
    };
    busy = true;
    _activeHeadTracked = correctedAngle != null;
    status = 'Cue → TTS 준비';
    _notify();
    unawaited(() async {
      try {
        final ok = await priority.speakObservation(
          _owner,
          command,
          valid,
          onDeadline: () => admission.cancel('PLAYBACK_WATCHDOG'),
        );
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
        _activeHeadTracked = false;
        _notify();
      }
    }());
  }

  int? _sceneDeadline;
  Map? _sceneBox;
  bool _sceneFresh() =>
      isCurrent() &&
      _sceneDeadline != null &&
      _now() < _sceneDeadline! &&
      scene.isFresh(DateTime.now().toUtc());

  void _observeScene(Map<String, Object?> result,
      {required Duration age,
      DateTime? receivedAt,
      double? inferenceMs,
      double? processingMs}) {
    final now = DateTime.now().toUtc();
    final rows = result['detections'];
    final size = result['imageSize'];
    // The local wire field is historically named capturedAt, but its producer
    // records the host camera callback receipt time, never sensor exposure.
    final receipt = receivedAt ??
        DateTime.tryParse(result['receivedAt']?.toString() ??
            result['capturedAt']?.toString() ??
            '');
    if (result['status'] != 'ok' ||
        result['source'] != 'android_camera' ||
        result['frameId'] is! String ||
        rows is! List ||
        receipt == null ||
        size is! Map ||
        size['width'] is! int ||
        size['height'] is! int ||
        size['width'] <= 0 ||
        size['height'] <= 0 ||
        age.isNegative ||
        age >= const Duration(seconds: 2)) {
      _expireScene('현재 화면을 확인하기 어렵습니다');
      return;
    }
    if (result['frameId'] == _lastFrame) return;
    _lastFrame = result['frameId'] as String;
    final unsupportedDoor = requireDoorInBus &&
        rows.any((row) =>
            row is Map &&
            row['classId'] == 'bus_door' &&
            (row['bbox'] is! Map ||
                !_isValidBoxMap(row['bbox'] as Map) ||
                _parentBusBox(row['bbox'] as Map, rows) == null));
    // Preserve parent-bus validation without silently omitting a doubtful door.
    final snapshot = _sceneTracker.update(
        frameId: _lastFrame!,
        receivedAt: receipt,
        now: now,
        detections: unsupportedDoor ? [<String, Object?>{}] : rows);
    if (!snapshot.isFresh(now)) {
      _expireScene('현재 화면을 확인하기 어렵습니다');
      return;
    }
    lastSceneReceivedAt = snapshot.receivedAt;
    _sceneDeadline =
        _now() + const Duration(seconds: 2).inMicroseconds - age.inMicroseconds;
    _sceneTimer?.cancel();
    _sceneTimer = Timer(const Duration(seconds: 2) - age,
        () => _expireScene('새 관찰 없음 · 현재 화면을 확인하기 어렵습니다'));
    final meaning = snapshot.signature;
    if (_sceneMeaning != meaning && busy) {
      _revision++;
      unawaited(_stopOwned());
    }
    _sceneMeaning = meaning;
    _sceneBox = null;
    if (snapshot.status == VisionSceneStatus.single) {
      final id = snapshot.groups.single.classCounts.keys.single;
      final matching = rows
          .whereType<Map>()
          .where((row) =>
              row['classId'] == id &&
              row['bbox'] is Map &&
              _isValidBoxMap(row['bbox'] as Map) &&
              row['confidence'] is num &&
              (row['confidence'] as num) >= .5)
          .toList();
      if (matching.length == 1) _sceneBox = matching.single['bbox'] as Map;
    }
    diagnostic = {
      'frameId': result['frameId'],
      'receivedAt': snapshot.receivedAt?.toIso8601String(),
      'clockProvenance': 'HOST_CAMERA_CALLBACK_RECEIPT_NOT_CAPTURE',
      'receiptAgeAtObservationMs': age.inMilliseconds,
      if (inferenceMs != null && inferenceMs.isFinite && inferenceMs >= 0)
        'inferenceMs': inferenceMs,
      if (processingMs != null && processingMs.isFinite && processingMs >= 0)
        'processingMs': processingMs,
      'sceneStatus': snapshot.status.name,
      'proximity': 'UNKNOWN',
      'risk': 'NOT_ESTIMATED',
      'text': snapshot.briefText,
      'provenance': DirectionalGuidance.screenProvenance,
      'guidanceEligible': false,
    };
    status = snapshot.briefText;
    _notify();
    if (!enabled ||
        busy ||
        priority.priorityActive ||
        priority.outputUncertain ||
        snapshot.reason == 'confirming') {
      return;
    }
    if ((!pingOnly && _lastMeaning == meaning) ||
        (_lastStarted != null &&
            _now() - _lastStarted! < minimumInterval.inMicroseconds)) {
      return;
    }
    unawaited(_speakScene(snapshot, details: false));
  }

  void _expireScene(String reason) {
    _sceneTimer?.cancel();
    _sceneDeadline = null;
    _sceneTracker.invalidate(reason: 'expired_or_invalid_result');
    _sceneMeaning = null;
    _revision++;
    status = reason;
    diagnostic = {
      ...diagnostic,
      'sceneStatus': 'unavailable',
      'proximity': 'UNKNOWN'
    };
    unawaited(_stopOwned());
    _notify();
  }

  Future<void> describeScene() async {
    if (!canDescribeScene || !_sceneFresh()) return;
    await _speakScene(scene, details: true);
  }

  Future<void> _speakScene(VisionSceneSummary snapshot,
      {required bool details}) async {
    if ((!enabled && !details) ||
        busy ||
        priority.priorityActive ||
        priority.outputUncertain ||
        !_sceneFresh()) {
      return;
    }
    // A multi-object scene has no single physical or screen target. Do not pan
    // a grouped summary or invent a direction for an uncertain observation.
    final single = snapshot.status == VisionSceneStatus.single;
    if (pingOnly && !single && !details) return;
    final revision = _revision, meaning = snapshot.signature;
    bool valid() =>
        !_disposed &&
        (enabled || details) &&
        revision == _revision &&
        _sceneFresh() &&
        _sceneMeaning == meaning &&
        !priority.priorityActive;
    final text = details ? snapshot.detailText : snapshot.briefText;
    final direction = single && !details
        ? switch (snapshot.groups.single.side) {
            VisionSceneSide.left => TestDirection.left,
            VisionSceneSide.center => TestDirection.center,
            VisionSceneSide.right => TestDirection.right,
          }
        : null;
    double? correctedAngle;
    final box = _sceneBox;
    if (single &&
        !details &&
        headTrackingEnabled &&
        canActivateHeadTracking &&
        box != null) {
      correctedAngle = headTrackedAngleForMount(
          cameraAngle: horizontalAngleForNormalizedBbox(
              x: (box['x'] as num).toDouble(),
              width: (box['w'] as num).toDouble(),
              horizontalFovDegrees: horizontalFovDegrees),
          sensor: headTracking.snapshot,
          now: DateTime.now().toUtc(),
          calibration: mountCalibration);
    }
    final guidance = DirectionalGuidance(
      guidanceId: 'scene-${++_sceneSequence}',
      sessionGeneration: sessionGeneration,
      authEpoch: 0,
      priority: GuidancePriority.observation,
      text: text,
      provenance: DirectionalGuidance.screenProvenance,
      testDirection: direction,
      headTrackedAzimuthDegrees: correctedAngle,
      directionEvidence: direction == null
          ? DirectionEvidence.unverified
          : DirectionEvidence.cameraScreenBbox,
    );
    var started = false;
    final requestStarted = _now();
    sceneOutputDiagnostic = {
      'phase': 'REQUESTED',
      'requestId': guidance.guidanceId,
      'clockProvenance': 'SOFTWARE_CALLBACK_NOT_ACOUSTIC'
    };
    final command = engine.registerGuidance(guidance, valid,
        phase: (phase) {
          if (!valid()) return;
          sceneOutputDiagnostic = {
            'phase': phase,
            'requestId': guidance.guidanceId,
            'callbackObservedAt': DateTime.now().toUtc().toIso8601String(),
            'requestElapsedMicros': _now() - requestStarted,
            'clockProvenance': 'SOFTWARE_CALLBACK_NOT_ACOUSTIC'
          };
          _notify();
        },
        cueOnly: pingOnly && !details && single,
        informationalTone:
            direction == null ? null : InformationalCueTone.neutral,
        admit: () {
          if (!valid()) return false;
          if (!started) {
            started = true;
            admitted++;
            _lastStarted = _now();
            _lastMeaning = meaning;
          }
          return true;
        });
    if (command == null) return;
    busy = true;
    _activeHeadTracked = correctedAngle != null;
    _notify();
    try {
      final ok = await priority.speakObservation(_owner, command, valid);
      if (ok) completed++;
      if (!ok && revision == _revision) {
        sceneOutputDiagnostic = {
          ...sceneOutputDiagnostic,
          'phase': 'CANCELLED'
        };
      }
    } catch (error) {
      if (valid()) {
        status = '장면 음성 출력 실패 · 오디오 연결을 확인하세요';
        sceneOutputDiagnostic = {...sceneOutputDiagnostic, 'phase': 'FAILED'};
      }
    } finally {
      engine.retireGuidance(command);
      busy = false;
      _activeHeadTracked = false;
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sceneTimer?.cancel();
    _sceneTracker.clear();
    enabled = false;
    _revision++;
    priority.removeListener(_priorityChanged);
    headTracking.removeListener(_headTrackingChanged);
    headTracking.resetForSession();
    mountCalibration = const HeadTrackingMountCalibration();
    _hold?.release();
    _hold = null;
    unawaited(_stopOwned());
    super.dispose();
  }
}
