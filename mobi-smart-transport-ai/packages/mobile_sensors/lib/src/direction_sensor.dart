enum DirectionAccuracy { high, medium, low, unknown }

extension DirectionAccuracyJson on DirectionAccuracy {
  String toJsonValue() {
    switch (this) {
      case DirectionAccuracy.high:
        return 'HIGH';
      case DirectionAccuracy.medium:
        return 'MEDIUM';
      case DirectionAccuracy.low:
        return 'LOW';
      case DirectionAccuracy.unknown:
        return 'UNKNOWN';
    }
  }

  static DirectionAccuracy fromJsonValue(String value) {
    switch (value) {
      case 'HIGH':
        return DirectionAccuracy.high;
      case 'MEDIUM':
        return DirectionAccuracy.medium;
      case 'LOW':
        return DirectionAccuracy.low;
      case 'UNKNOWN':
        return DirectionAccuracy.unknown;
      default:
        throw ArgumentError('Unknown DirectionAccuracy JSON value: $value');
    }
  }
}

class DirectionReading {
  final double headingDegrees;
  final DirectionAccuracy accuracy;
  final DateTime updatedAt;

  const DirectionReading({
    required this.headingDegrees,
    required this.accuracy,
    required this.updatedAt,
  });

  Map<String, Object?> toJson() => {
        'headingDegrees': headingDegrees,
        'accuracy': accuracy.toJsonValue(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory DirectionReading.fromJson(Map<String, Object?> json) => DirectionReading(
        headingDegrees: (json['headingDegrees'] as num).toDouble(),
        accuracy: DirectionAccuracyJson.fromJsonValue(json['accuracy'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

abstract class DirectionSensor {
  Stream<DirectionReading> readings();
}

class UnimplementedDirectionSensor implements DirectionSensor {
  @override
  Stream<DirectionReading> readings() {
    // TODO(안준환): 스마트폰 나침반/방향 센서 구현.
    return const Stream.empty();
  }
}
