import 'sensor_model_validation.dart';

enum BeaconSignalLevel { veryClose, close, medium, far, lost }

extension BeaconSignalLevelJson on BeaconSignalLevel {
  String toJsonValue() {
    switch (this) {
      case BeaconSignalLevel.veryClose:
        return 'VERY_CLOSE';
      case BeaconSignalLevel.close:
        return 'CLOSE';
      case BeaconSignalLevel.medium:
        return 'MEDIUM';
      case BeaconSignalLevel.far:
        return 'FAR';
      case BeaconSignalLevel.lost:
        return 'LOST';
    }
  }

  static BeaconSignalLevel fromJsonValue(String value) {
    switch (value) {
      case 'VERY_CLOSE':
        return BeaconSignalLevel.veryClose;
      case 'CLOSE':
        return BeaconSignalLevel.close;
      case 'MEDIUM':
        return BeaconSignalLevel.medium;
      case 'FAR':
        return BeaconSignalLevel.far;
      case 'LOST':
        return BeaconSignalLevel.lost;
      default:
        throw ArgumentError('Unknown BeaconSignalLevel JSON value: $value');
    }
  }
}

class BeaconSignal {
  final String beaconId;
  final int rssi;
  final double? estimatedDistanceMeters;
  final BeaconSignalLevel signalLevel;
  final DateTime lastDetectedAt;

  const BeaconSignal({
    required this.beaconId,
    required this.rssi,
    required this.estimatedDistanceMeters,
    required this.signalLevel,
    required this.lastDetectedAt,
  })  : assert(beaconId.length > 0, 'beaconId must not be empty'),
        assert(
          rssi >= SensorModelValidation.minValidRssi &&
              rssi <= SensorModelValidation.maxValidRssi,
          'rssi must be between -127 and -1',
        ),
        assert(
          estimatedDistanceMeters == null || estimatedDistanceMeters >= 0,
          'estimatedDistanceMeters must be non-negative or null',
        );

  bool get isLost => signalLevel == BeaconSignalLevel.lost;

  bool wasDetectedWithin(Duration maxAge, {DateTime? now}) {
    final referenceTime = now ?? DateTime.now();
    return referenceTime.difference(lastDetectedAt) <= maxAge;
  }

  BeaconSignal copyWith({
    String? beaconId,
    int? rssi,
    double? estimatedDistanceMeters,
    bool clearEstimatedDistanceMeters = false,
    BeaconSignalLevel? signalLevel,
    DateTime? lastDetectedAt,
  }) {
    return BeaconSignal(
      beaconId: beaconId ?? this.beaconId,
      rssi: rssi ?? this.rssi,
      estimatedDistanceMeters: clearEstimatedDistanceMeters
          ? null
          : estimatedDistanceMeters ?? this.estimatedDistanceMeters,
      signalLevel: signalLevel ?? this.signalLevel,
      lastDetectedAt: lastDetectedAt ?? this.lastDetectedAt,
    );
  }

  Map<String, Object?> toJson() => {
        'beaconId': beaconId,
        'rssi': rssi,
        'estimatedDistanceMeters': estimatedDistanceMeters,
        'signalLevel': signalLevel.toJsonValue(),
        'lastDetectedAt': lastDetectedAt.toIso8601String(),
      };

  factory BeaconSignal.fromJson(Map<String, Object?> json) {
    final beaconId = json['beaconId'];
    final rssi = json['rssi'];
    final estimatedDistanceMeters = json['estimatedDistanceMeters'];
    final signalLevel = json['signalLevel'];
    final lastDetectedAt = json['lastDetectedAt'];

    if (beaconId != null && beaconId is! String) {
      throw ArgumentError('BeaconSignal.beaconId must be a string or null.');
    }
    if (signalLevel is! String) {
      throw ArgumentError('BeaconSignal.signalLevel must be a string.');
    }

    return BeaconSignal(
      beaconId: SensorModelValidation.normalizeBeaconId(beaconId as String?),
      rssi: SensorModelValidation.requireValidRssi(
        rssi,
        fieldName: 'BeaconSignal.rssi',
      ),
      estimatedDistanceMeters:
          SensorModelValidation.normalizeEstimatedDistanceMeters(
        estimatedDistanceMeters,
        fieldName: 'BeaconSignal.estimatedDistanceMeters',
      ),
      signalLevel: BeaconSignalLevelJson.fromJsonValue(signalLevel),
      lastDetectedAt: SensorModelValidation.requireIsoTimestamp(
        lastDetectedAt,
        fieldName: 'BeaconSignal.lastDetectedAt',
      ),
    );
  }

  factory BeaconSignal.lost({
    required String beaconId,
    DateTime? lastDetectedAt,
  }) {
    return BeaconSignal(
      beaconId: SensorModelValidation.normalizeBeaconId(beaconId),
      rssi: SensorModelValidation.minValidRssi,
      estimatedDistanceMeters: null,
      signalLevel: BeaconSignalLevel.lost,
      lastDetectedAt: lastDetectedAt ?? DateTime.now(),
    );
  }
}
