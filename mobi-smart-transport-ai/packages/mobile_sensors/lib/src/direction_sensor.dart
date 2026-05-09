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

  DirectionReading({
    required double headingDegrees,
    required this.accuracy,
    required this.updatedAt,
  }) : headingDegrees = normalizeHeadingDegrees(headingDegrees);

  /// 스마트폰 나침반 heading 값을 0도 이상 360도 미만 범위로 정규화한다.
  ///
  /// 플랫폼별 센서 플러그인은 -10도, 361도처럼 범위를 벗어난 값을 줄 수 있다.
  /// 이 패키지는 앱 UI가 아니라 모델 계층에서 JSON 계약을 안정적으로 유지하기
  /// 위해 값을 [0, 360) 범위로 맞춘다.
  static double normalizeHeadingDegrees(double headingDegrees) {
    final normalized = headingDegrees % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  DirectionReading copyWith({
    double? headingDegrees,
    DirectionAccuracy? accuracy,
    DateTime? updatedAt,
  }) {
    return DirectionReading(
      headingDegrees: headingDegrees ?? this.headingDegrees,
      accuracy: accuracy ?? this.accuracy,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
        'headingDegrees': headingDegrees,
        'accuracy': accuracy.toJsonValue(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory DirectionReading.fromJson(Map<String, Object?> json) {
    final headingDegrees = json['headingDegrees'];
    final accuracy = json['accuracy'];
    final updatedAt = json['updatedAt'];

    if (headingDegrees is! num) {
      throw ArgumentError('DirectionReading.headingDegrees must be a number.');
    }
    if (accuracy is! String) {
      throw ArgumentError('DirectionReading.accuracy must be a string.');
    }
    if (updatedAt is! String) {
      throw ArgumentError('DirectionReading.updatedAt must be an ISO-8601 string.');
    }

    return DirectionReading(
      headingDegrees: headingDegrees.toDouble(),
      accuracy: DirectionAccuracyJson.fromJsonValue(accuracy),
      updatedAt: DateTime.parse(updatedAt),
    );
  }

  factory DirectionReading.unknown({DateTime? updatedAt}) {
    return DirectionReading(
      headingDegrees: 0,
      accuracy: DirectionAccuracy.unknown,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

abstract class DirectionSensor {
  bool get isListening;

  Stream<DirectionReading> readings();
  Future<void> stop();
}

class UnimplementedDirectionSensor implements DirectionSensor {
  bool _isListening = false;

  @override
  bool get isListening => _isListening;

  @override
  Stream<DirectionReading> readings() async* {
    // TODO(안준환): 스마트폰 나침반/방향 센서 구현.
    // 이 skeleton은 앱 UI가 아니라 패키지 내부 direction sensor lifecycle 계약만 표현한다.
    _isListening = true;
    try {
      yield* const Stream<DirectionReading>.empty();
    } finally {
      _isListening = false;
    }
  }

  @override
  Future<void> stop() async {
    _isListening = false;
  }
}

class MockDirectionSensor implements DirectionSensor {
  MockDirectionSensor(this.values);

  final Iterable<DirectionReading> values;
  bool _isListening = false;

  @override
  bool get isListening => _isListening;

  @override
  Stream<DirectionReading> readings() async* {
    _isListening = true;
    try {
      for (final value in values) {
        if (!_isListening) {
          break;
        }
        yield value;
      }
    } finally {
      _isListening = false;
    }
  }

  @override
  Future<void> stop() async {
    _isListening = false;
  }
}
