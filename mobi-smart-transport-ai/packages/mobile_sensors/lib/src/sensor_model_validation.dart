/// 공통 센서 모델 검증 helper.
///
/// 이 파일은 Flutter 앱 UI나 실제 BLE scan을 구현하지 않고, sensor 모델이 JSON
/// payload를 안전하게 읽고 앱 계층에 넘길 수 있도록 값 검증 기준만 제공한다.
class SensorModelValidation {
  const SensorModelValidation._();

  /// 비콘 ID를 알 수 없거나 비어 있을 때 사용하는 안전 fallback 값이다.
  static const String unknownBeaconId = 'UNKNOWN_BEACON';

  /// BLE RSSI에서 일반적으로 허용하는 최소 sentinel 값이다.
  static const int minValidRssi = -127;

  /// BLE scan 결과로 볼 수 있는 최대 RSSI 값이다.
  static const int maxValidRssi = -1;

  /// beaconId가 null/blank이면 [unknownBeaconId]로 정규화한다.
  static String normalizeBeaconId(String? beaconId) {
    final normalized = beaconId?.trim() ?? '';
    return normalized.isEmpty ? unknownBeaconId : normalized;
  }

  /// 정규화 후에도 unknown beacon인지 확인한다.
  static bool isUnknownBeaconId(String? beaconId) {
    return normalizeBeaconId(beaconId) == unknownBeaconId;
  }

  /// BLE RSSI로 사용할 수 있는 범위인지 확인한다.
  static bool isValidRssi(int rssi) {
    return rssi >= minValidRssi && rssi <= maxValidRssi;
  }

  /// JSON payload에서 RSSI 값을 안전하게 읽는다.
  ///
  /// RSSI는 정수이며 `-127..-1` 범위만 허용한다. `0`, 양수, NaN, 무한대,
  /// 소수점 RSSI는 invalid payload로 처리한다.
  static int requireValidRssi(Object? value, {String fieldName = 'rssi'}) {
    if (value is! num || !value.isFinite || value % 1 != 0) {
      throw ArgumentError('$fieldName must be an integer RSSI value.');
    }

    final rssi = value.toInt();
    if (!isValidRssi(rssi)) {
      throw ArgumentError(
        '$fieldName must be between $minValidRssi and $maxValidRssi.',
      );
    }
    return rssi;
  }

  /// 거리 추정값을 안전하게 읽는다.
  ///
  /// 추정 불가 상태는 null로 유지하고, 음수/NaN/무한대는 invalid payload로 본다.
  static double? normalizeEstimatedDistanceMeters(
    Object? value, {
    String fieldName = 'estimatedDistanceMeters',
  }) {
    if (value == null) {
      return null;
    }
    if (value is! num || !value.isFinite || value < 0) {
      throw ArgumentError('$fieldName must be a non-negative number or null.');
    }
    return value.toDouble();
  }

  /// ISO-8601 timestamp를 안전하게 읽는다.
  static DateTime requireIsoTimestamp(
    Object? value, {
    String fieldName = 'timestamp',
  }) {
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('$fieldName must be a non-empty ISO-8601 string.');
    }

    try {
      return DateTime.parse(value);
    } on FormatException catch (error) {
      throw ArgumentError('$fieldName must be a valid ISO-8601 string: $error');
    }
  }
}
