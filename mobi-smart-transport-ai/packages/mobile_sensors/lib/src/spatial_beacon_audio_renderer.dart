import 'beacon_signal.dart';
import 'bone_conduction_audio_cue.dart';
import 'direction_sensor.dart';

class SpatialBeaconAudioProfile {
  const SpatialBeaconAudioProfile({
    this.minGain = 0.22,
    this.maxGain = 1.0,
    this.maxGuidanceDistanceMeters = 8.0,
    this.arrivalDistanceThresholdMeters = 0.45,
    this.arrivalRssiThreshold = -48,
    this.minBeepIntervalMs = 260,
    this.maxBeepIntervalMs = 1800,
    this.dangerBeepIntervalMs = 420,
    this.lostBeepIntervalMs = 1200,
    this.maxPanBearingDegrees = 90,
  })  : assert(minGain >= 0 && minGain <= 1, 'minGain must be 0..1'),
        assert(maxGain >= 0 && maxGain <= 1, 'maxGain must be 0..1'),
        assert(maxGain >= minGain, 'maxGain must be >= minGain'),
        assert(
          maxGuidanceDistanceMeters > arrivalDistanceThresholdMeters,
          'maxGuidanceDistanceMeters must be greater than arrival threshold',
        ),
        assert(arrivalDistanceThresholdMeters >= 0),
        assert(minBeepIntervalMs >= 0),
        assert(maxBeepIntervalMs >= minBeepIntervalMs),
        assert(dangerBeepIntervalMs >= 0),
        assert(lostBeepIntervalMs >= 0),
        assert(maxPanBearingDegrees > 0);

  final double minGain;
  final double maxGain;
  final double maxGuidanceDistanceMeters;
  final double arrivalDistanceThresholdMeters;
  final int arrivalRssiThreshold;
  final int minBeepIntervalMs;
  final int maxBeepIntervalMs;
  final int dangerBeepIntervalMs;
  final int lostBeepIntervalMs;
  final double maxPanBearingDegrees;
}

class SpatialBeaconAudioRenderState {
  const SpatialBeaconAudioRenderState({
    required this.gain,
    required this.leftGain,
    required this.rightGain,
    required this.pan,
    required this.relativeBearingDegrees,
    required this.beepIntervalMs,
    required this.isArrival,
    required this.isLost,
  });

  final double gain;
  final double leftGain;
  final double rightGain;
  final double pan;
  final double relativeBearingDegrees;
  final int beepIntervalMs;
  final bool isArrival;
  final bool isLost;

  Map<String, Object?> toJson() => <String, Object?>{
        'gain': gain,
        'leftGain': leftGain,
        'rightGain': rightGain,
        'pan': pan,
        'relativeBearingDegrees': relativeBearingDegrees,
        'beepIntervalMs': beepIntervalMs,
        'isArrival': isArrival,
        'isLost': isLost,
      };
}

class SpatialBeaconAudioRenderer {
  const SpatialBeaconAudioRenderer({
    this.profile = const SpatialBeaconAudioProfile(),
  });

  final SpatialBeaconAudioProfile profile;

  SpatialBeaconAudioRenderState renderDoorGuidance({
    required BeaconSignal signal,
    DirectionReading? direction,
    double beaconBearingDegrees = 0,
  }) {
    final relativeBearing = relativeBearingDegrees(
      userHeadingDegrees: direction?.headingDegrees ?? beaconBearingDegrees,
      beaconBearingDegrees: beaconBearingDegrees,
    );

    if (signal.isLost) {
      return _state(
        gain: 0,
        relativeBearingDegrees: relativeBearing,
        beepIntervalMs: profile.lostBeepIntervalMs,
        isArrival: false,
        isLost: true,
      );
    }

    final distanceMeters = _distanceForGuidance(signal);
    final isArrival = _isArrival(signal, distanceMeters);
    if (isArrival) {
      return _state(
        gain: 0,
        relativeBearingDegrees: relativeBearing,
        beepIntervalMs: 0,
        isArrival: true,
        isLost: false,
      );
    }

    final closeness = _closeness(distanceMeters);
    final frontFactor = 1 - (relativeBearing.abs() / 180).clamp(0, 1);
    final directionalWeight = 0.68 + (0.32 * frontFactor);
    final gain =
        _lerp(profile.minGain, profile.maxGain, closeness) * directionalWeight;
    final interval = _lerp(
      profile.maxBeepIntervalMs.toDouble(),
      profile.minBeepIntervalMs.toDouble(),
      closeness,
    ).round();

    return _state(
      gain: gain,
      relativeBearingDegrees: relativeBearing,
      beepIntervalMs: interval,
      isArrival: false,
      isLost: false,
    );
  }

  BoneConductionAudioCue createDoorGuidanceCue({
    required BeaconSignal signal,
    DirectionReading? direction,
    double beaconBearingDegrees = 0,
    DateTime? createdAt,
  }) {
    final timestamp = createdAt ?? DateTime.now();
    final renderState = renderDoorGuidance(
      signal: signal,
      direction: direction,
      beaconBearingDegrees: beaconBearingDegrees,
    );

    if (renderState.isArrival) {
      return _cue(
        cueIdPrefix: 'door-arrived',
        signal: signal,
        message: '출입문에 도착했어, 탑승해',
        urgency: BoneConductionCueUrgency.low,
        renderState: renderState,
        shouldRepeat: false,
        createdAt: timestamp,
      );
    }

    if (renderState.isLost) {
      return _cue(
        cueIdPrefix: 'door-lost',
        signal: signal,
        message: '출입문 비콘 신호가 약해졌어. 천천히 다시 방향을 찾아줘',
        urgency: BoneConductionCueUrgency.high,
        renderState: renderState,
        shouldRepeat: true,
        createdAt: timestamp,
      );
    }

    return _cue(
      cueIdPrefix: 'door-guidance',
      signal: signal,
      message: '출입문 방향 안내 beep',
      urgency: _urgencyForDoor(signal),
      renderState: renderState,
      shouldRepeat: true,
      createdAt: timestamp,
    );
  }

  BoneConductionAudioCue createDangerCue({
    required BeaconSignal signal,
    DirectionReading? direction,
    double beaconBearingDegrees = 0,
    DateTime? createdAt,
  }) {
    final timestamp = createdAt ?? DateTime.now();
    final relativeBearing = relativeBearingDegrees(
      userHeadingDegrees: direction?.headingDegrees ?? beaconBearingDegrees,
      beaconBearingDegrees: beaconBearingDegrees,
    );
    final renderState = _state(
      gain: profile.maxGain,
      relativeBearingDegrees: relativeBearing,
      beepIntervalMs: profile.dangerBeepIntervalMs,
      isArrival: false,
      isLost: signal.isLost,
    );

    return _cue(
      cueIdPrefix: 'danger-beacon',
      signal: signal,
      message: '위험구역이야, 물러나',
      urgency: BoneConductionCueUrgency.critical,
      renderState: renderState,
      shouldRepeat: true,
      createdAt: timestamp,
    );
  }

  static double normalizeDegrees(double degrees) {
    if (!degrees.isFinite) {
      throw ArgumentError('degrees must be finite.');
    }
    final normalized = degrees % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  static double relativeBearingDegrees({
    required double userHeadingDegrees,
    required double beaconBearingDegrees,
  }) {
    final relative = normalizeDegrees(beaconBearingDegrees) -
        normalizeDegrees(userHeadingDegrees);
    if (relative > 180) return relative - 360;
    if (relative <= -180) return relative + 360;
    return relative;
  }

  SpatialBeaconAudioRenderState _state({
    required double gain,
    required double relativeBearingDegrees,
    required int beepIntervalMs,
    required bool isArrival,
    required bool isLost,
  }) {
    final safeGain = gain.clamp(0, 1).toDouble();
    final pan = (relativeBearingDegrees / profile.maxPanBearingDegrees)
        .clamp(-1, 1)
        .toDouble();
    final leftGain = safeGain * (pan <= 0 ? 1 : 1 - pan);
    final rightGain = safeGain * (pan >= 0 ? 1 : 1 + pan);

    return SpatialBeaconAudioRenderState(
      gain: safeGain,
      leftGain: leftGain.clamp(0, 1).toDouble(),
      rightGain: rightGain.clamp(0, 1).toDouble(),
      pan: pan,
      relativeBearingDegrees: relativeBearingDegrees,
      beepIntervalMs: beepIntervalMs,
      isArrival: isArrival,
      isLost: isLost,
    );
  }

  BoneConductionAudioCue _cue({
    required String cueIdPrefix,
    required BeaconSignal signal,
    required String message,
    required BoneConductionCueUrgency urgency,
    required SpatialBeaconAudioRenderState renderState,
    required bool shouldRepeat,
    required DateTime createdAt,
  }) {
    return BoneConductionAudioCue(
      cueId:
          '$cueIdPrefix-${signal.beaconId}-${createdAt.millisecondsSinceEpoch}',
      beaconId: signal.beaconId,
      message: message,
      signalLevel: signal.signalLevel,
      estimatedDistanceMeters: signal.estimatedDistanceMeters,
      urgency: urgency,
      repeatIntervalMs: renderState.beepIntervalMs,
      shouldRepeat: shouldRepeat,
      gain: renderState.gain,
      leftGain: renderState.leftGain,
      rightGain: renderState.rightGain,
      pan: renderState.pan,
      relativeBearingDegrees: renderState.relativeBearingDegrees,
      createdAt: createdAt,
    );
  }

  bool _isArrival(BeaconSignal signal, double distanceMeters) {
    return distanceMeters <= profile.arrivalDistanceThresholdMeters ||
        signal.rssi >= profile.arrivalRssiThreshold;
  }

  double _distanceForGuidance(BeaconSignal signal) {
    final distance = signal.estimatedDistanceMeters;
    if (distance != null && distance.isFinite && distance >= 0) {
      return distance;
    }
    switch (signal.signalLevel) {
      case BeaconSignalLevel.veryClose:
        return profile.arrivalDistanceThresholdMeters;
      case BeaconSignalLevel.close:
        return 1.8;
      case BeaconSignalLevel.medium:
        return 4.0;
      case BeaconSignalLevel.far:
        return profile.maxGuidanceDistanceMeters;
      case BeaconSignalLevel.lost:
        return profile.maxGuidanceDistanceMeters;
    }
  }

  double _closeness(double distanceMeters) {
    final span = profile.maxGuidanceDistanceMeters -
        profile.arrivalDistanceThresholdMeters;
    final normalized =
        1 - ((distanceMeters - profile.arrivalDistanceThresholdMeters) / span);
    return normalized.clamp(0, 1).toDouble();
  }

  BoneConductionCueUrgency _urgencyForDoor(BeaconSignal signal) {
    switch (signal.signalLevel) {
      case BeaconSignalLevel.veryClose:
      case BeaconSignalLevel.close:
        return BoneConductionCueUrgency.medium;
      case BeaconSignalLevel.medium:
        return BoneConductionCueUrgency.medium;
      case BeaconSignalLevel.far:
        return BoneConductionCueUrgency.high;
      case BeaconSignalLevel.lost:
        return BoneConductionCueUrgency.high;
    }
  }

  double _lerp(double start, double end, double t) {
    return start + ((end - start) * t.clamp(0, 1));
  }
}
