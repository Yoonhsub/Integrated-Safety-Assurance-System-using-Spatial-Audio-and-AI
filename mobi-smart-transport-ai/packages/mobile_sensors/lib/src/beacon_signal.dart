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
  });

  Map<String, Object?> toJson() => {
        'beaconId': beaconId,
        'rssi': rssi,
        'estimatedDistanceMeters': estimatedDistanceMeters,
        'signalLevel': signalLevel.toJsonValue(),
        'lastDetectedAt': lastDetectedAt.toIso8601String(),
      };

  factory BeaconSignal.fromJson(Map<String, Object?> json) => BeaconSignal(
        beaconId: json['beaconId'] as String,
        rssi: json['rssi'] as int,
        estimatedDistanceMeters: (json['estimatedDistanceMeters'] as num?)?.toDouble(),
        signalLevel: BeaconSignalLevelJson.fromJsonValue(json['signalLevel'] as String),
        lastDetectedAt: DateTime.parse(json['lastDetectedAt'] as String),
      );
}
