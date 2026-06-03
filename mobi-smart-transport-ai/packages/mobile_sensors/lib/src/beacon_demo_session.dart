import 'beacon_distance_estimator.dart';
import 'beacon_proximity_tracker.dart';
import 'beacon_scanner.dart';
import 'beacon_signal.dart';
import 'bone_conduction_audio_cue.dart';
import 'direction_sensor.dart';
import 'spatial_beacon_audio_renderer.dart';

typedef BeaconDemoDirectionProvider = DirectionReading? Function(
  BeaconSignal signal,
);

enum BeaconDemoRole { door, danger }

enum BeaconDemoStatus {
  guidingDoor,
  doorArrived,
  dangerActive,
  dangerCleared,
  beaconLost,
  idle,
}

extension BeaconDemoStatusJson on BeaconDemoStatus {
  String toJsonValue() {
    switch (this) {
      case BeaconDemoStatus.guidingDoor:
        return 'GUIDING_DOOR';
      case BeaconDemoStatus.doorArrived:
        return 'DOOR_ARRIVED';
      case BeaconDemoStatus.dangerActive:
        return 'DANGER_ACTIVE';
      case BeaconDemoStatus.dangerCleared:
        return 'DANGER_CLEARED';
      case BeaconDemoStatus.beaconLost:
        return 'BEACON_LOST';
      case BeaconDemoStatus.idle:
        return 'IDLE';
    }
  }
}

class BeaconDemoConfig {
  const BeaconDemoConfig({
    this.doorBeaconId = 'MOBI_DOOR_BEACON_001',
    this.dangerBeaconId = 'MOBI_DANGER_BEACON_001',
    this.doorBeaconBearingDegrees = 0,
    this.dangerBeaconBearingDegrees = 0,
    this.dangerEnterRssiThreshold = -62,
    this.dangerReleaseRssiThreshold = -75,
    this.dangerEnterDistanceMeters = 1.5,
    this.dangerReleaseDistanceMeters = 2.6,
    this.renderer = const SpatialBeaconAudioRenderer(),
    this.estimator = const BeaconDistanceEstimator(),
  })  : assert(dangerReleaseRssiThreshold < dangerEnterRssiThreshold),
        assert(dangerEnterDistanceMeters >= 0),
        assert(dangerReleaseDistanceMeters >= dangerEnterDistanceMeters);

  final String doorBeaconId;
  final String dangerBeaconId;
  final double doorBeaconBearingDegrees;
  final double dangerBeaconBearingDegrees;
  final int dangerEnterRssiThreshold;
  final int dangerReleaseRssiThreshold;
  final double dangerEnterDistanceMeters;
  final double dangerReleaseDistanceMeters;
  final SpatialBeaconAudioRenderer renderer;
  final BeaconDistanceEstimator estimator;
}

class BeaconDemoSnapshot {
  const BeaconDemoSnapshot({
    required this.role,
    required this.status,
    required this.beaconId,
    required this.signal,
    required this.cue,
    required this.createdAt,
    this.direction,
    this.trend,
    this.message,
    this.dangerActive = false,
  });

  final BeaconDemoRole role;
  final BeaconDemoStatus status;
  final String beaconId;
  final BeaconSignal signal;
  final DirectionReading? direction;
  final BeaconProximityTrend? trend;
  final BoneConductionAudioCue cue;
  final String? message;
  final bool dangerActive;
  final DateTime createdAt;

  bool get isDoorGuidance => status == BeaconDemoStatus.guidingDoor;
  bool get isDoorArrived => status == BeaconDemoStatus.doorArrived;
  bool get isDangerActive => status == BeaconDemoStatus.dangerActive;
  bool get isBeaconLost => status == BeaconDemoStatus.beaconLost;

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role.name,
        'status': status.toJsonValue(),
        'beaconId': beaconId,
        'signal': signal.toJson(),
        'direction': direction?.toJson(),
        'trend': trend?.toJsonValue(),
        'cue': cue.toJson(),
        'message': message,
        'dangerActive': dangerActive,
        'createdAt': createdAt.toIso8601String(),
      };
}

class BeaconDemoController {
  BeaconDemoController({
    BeaconDemoConfig config = const BeaconDemoConfig(),
    BeaconProximityTracker? tracker,
  })  : config = config,
        _tracker = tracker ?? BeaconProximityTracker();

  final BeaconDemoConfig config;
  final BeaconProximityTracker _tracker;
  bool _dangerActive = false;

  bool get dangerActive => _dangerActive;

  void reset() {
    _dangerActive = false;
    _tracker.reset();
  }

  BeaconDemoSnapshot evaluateDoorSignal(
    BeaconSignal signal, {
    DirectionReading? direction,
    DateTime? createdAt,
  }) {
    final timestamp = createdAt ?? DateTime.now();
    final snapshot = _tracker.addSignal(signal, now: timestamp);
    final cue = config.renderer.createDoorGuidanceCue(
      signal: signal,
      direction: direction,
      beaconBearingDegrees: config.doorBeaconBearingDegrees,
      createdAt: timestamp,
    );
    final status = signal.isLost
        ? BeaconDemoStatus.beaconLost
        : cue.shouldRepeat
            ? BeaconDemoStatus.guidingDoor
            : BeaconDemoStatus.doorArrived;

    return BeaconDemoSnapshot(
      role: BeaconDemoRole.door,
      status: status,
      beaconId: signal.beaconId,
      signal: signal,
      direction: direction,
      trend: snapshot.trend,
      cue: cue,
      message: _messageFor(status),
      createdAt: timestamp,
    );
  }

  BeaconDemoSnapshot evaluateDangerSignal(
    BeaconSignal signal, {
    DirectionReading? direction,
    DateTime? createdAt,
  }) {
    final timestamp = createdAt ?? DateTime.now();
    final wasActive = _dangerActive;
    final shouldEnter = _isDangerEnter(signal);
    final shouldRelease = _isDangerRelease(signal);

    if (signal.isLost) {
      _dangerActive = false;
    } else if (shouldEnter) {
      _dangerActive = true;
    } else if (wasActive && shouldRelease) {
      _dangerActive = false;
    }

    final status = signal.isLost
        ? BeaconDemoStatus.beaconLost
        : _dangerActive
            ? BeaconDemoStatus.dangerActive
            : BeaconDemoStatus.dangerCleared;

    final cue = _dangerActive
        ? config.renderer.createDangerCue(
            signal: signal,
            direction: direction,
            beaconBearingDegrees: config.dangerBeaconBearingDegrees,
            createdAt: timestamp,
          )
        : BoneConductionAudioCue(
            cueId:
                'danger-clear-${signal.beaconId}-${timestamp.millisecondsSinceEpoch}',
            beaconId: signal.beaconId,
            message: '위험구역을 벗어났어',
            signalLevel: signal.signalLevel,
            estimatedDistanceMeters: signal.estimatedDistanceMeters,
            urgency: BoneConductionCueUrgency.low,
            repeatIntervalMs: 0,
            shouldRepeat: false,
            gain: 0,
            leftGain: 0,
            rightGain: 0,
            pan: 0,
            relativeBearingDegrees: 0,
            createdAt: timestamp,
          );

    return BeaconDemoSnapshot(
      role: BeaconDemoRole.danger,
      status: status,
      beaconId: signal.beaconId,
      signal: signal,
      direction: direction,
      cue: cue,
      message: _messageFor(status),
      dangerActive: _dangerActive,
      createdAt: timestamp,
    );
  }

  bool _isDangerEnter(BeaconSignal signal) {
    final distance = signal.estimatedDistanceMeters;
    return signal.rssi >= config.dangerEnterRssiThreshold ||
        (distance != null && distance <= config.dangerEnterDistanceMeters);
  }

  bool _isDangerRelease(BeaconSignal signal) {
    final distance = signal.estimatedDistanceMeters;
    return signal.rssi <= config.dangerReleaseRssiThreshold ||
        (distance != null && distance >= config.dangerReleaseDistanceMeters);
  }

  String _messageFor(BeaconDemoStatus status) {
    switch (status) {
      case BeaconDemoStatus.guidingDoor:
        return '출입문 비콘을 따라가는 중';
      case BeaconDemoStatus.doorArrived:
        return '출입문 도착';
      case BeaconDemoStatus.dangerActive:
        return '위험 비콘 근접';
      case BeaconDemoStatus.dangerCleared:
        return '위험 비콘 해제';
      case BeaconDemoStatus.beaconLost:
        return '비콘 신호 분실';
      case BeaconDemoStatus.idle:
        return '대기 중';
    }
  }
}

class BeaconDemoSession {
  BeaconDemoSession({
    required BeaconScanner scanner,
    BeaconDemoController? controller,
    BeaconDemoConfig config = const BeaconDemoConfig(),
  })  : _scanner = scanner,
        _controller = controller ?? BeaconDemoController(config: config);

  final BeaconScanner _scanner;
  final BeaconDemoController _controller;

  BeaconDemoConfig get config => _controller.config;
  bool get isScanning => _scanner.isScanning;

  Stream<BeaconDemoSnapshot> watchDoorGuidance({
    BeaconDemoDirectionProvider? directionProvider,
  }) async* {
    try {
      await for (final signal
          in _scanner.scan(targetBeaconId: config.doorBeaconId)) {
        final snapshot = _controller.evaluateDoorSignal(
          signal,
          direction: directionProvider?.call(signal),
        );
        yield snapshot;
        if (snapshot.isDoorArrived) {
          break;
        }
      }
    } finally {
      await stop();
    }
  }

  Stream<BeaconDemoSnapshot> watchDangerZone({
    BeaconDemoDirectionProvider? directionProvider,
  }) async* {
    try {
      await for (final signal
          in _scanner.scan(targetBeaconId: config.dangerBeaconId)) {
        yield _controller.evaluateDangerSignal(
          signal,
          direction: directionProvider?.call(signal),
        );
      }
    } finally {
      await stop();
    }
  }

  Future<void> stop() async {
    await _scanner.stop();
  }
}
