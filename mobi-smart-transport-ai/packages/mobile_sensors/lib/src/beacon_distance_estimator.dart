import 'dart:collection';
import 'dart:math';

import 'beacon_signal.dart';
import 'sensor_model_validation.dart';

/// 앱 안내에서 사용할 RSSI 기반 거리 구간이다.
///
/// V2 섹션 3에서는 정밀한 meter 값보다 `near`, `medium`, `far`, `unknown`
/// 구간이 흔들리지 않게 유지되는 것을 우선한다.
enum BeaconDistanceZone { near, medium, far, unknown }

extension BeaconDistanceZoneJson on BeaconDistanceZone {
  String toJsonValue() {
    switch (this) {
      case BeaconDistanceZone.near:
        return 'NEAR';
      case BeaconDistanceZone.medium:
        return 'MEDIUM';
      case BeaconDistanceZone.far:
        return 'FAR';
      case BeaconDistanceZone.unknown:
        return 'UNKNOWN';
    }
  }

  static BeaconDistanceZone fromJsonValue(String value) {
    switch (value) {
      case 'NEAR':
        return BeaconDistanceZone.near;
      case 'MEDIUM':
        return BeaconDistanceZone.medium;
      case 'FAR':
        return BeaconDistanceZone.far;
      case 'UNKNOWN':
        return BeaconDistanceZone.unknown;
      default:
        throw ArgumentError('Unknown BeaconDistanceZone JSON value: $value');
    }
  }
}

/// RSSI/거리 계산 결과를 앱이 안정적인 구간 기준으로 소비할 수 있게 묶은 값이다.
class BeaconDistanceEstimate {
  const BeaconDistanceEstimate({
    required this.rssi,
    required this.signalLevel,
    required this.distanceZone,
    required this.estimatedDistanceMeters,
  }) : assert(
          estimatedDistanceMeters == null || estimatedDistanceMeters >= 0,
          'estimatedDistanceMeters must be non-negative or null',
        );

  final int rssi;
  final BeaconSignalLevel signalLevel;
  final BeaconDistanceZone distanceZone;
  final double? estimatedDistanceMeters;

  bool get isUnknown => distanceZone == BeaconDistanceZone.unknown;

  Map<String, Object?> toJson() => {
        'rssi': rssi,
        'signalLevel': signalLevel.toJsonValue(),
        'distanceZone': distanceZone.toJsonValue(),
        'estimatedDistanceMeters': estimatedDistanceMeters,
      };
}

/// RSSI 값으로부터 초기 거리 추정값과 가까움/멀어짐 상태를 계산한다.
///
/// RSSI 기반 거리는 실내 구조, 비콘 제조사, 스마트폰 기종, 사람/벽 간섭에
/// 크게 영향을 받는다. 따라서 이 클래스의 기본값은 현장 보정 전 스캐폴딩
/// 기준값이며, 실제 서비스 적용 전 비콘별 `txPower`와 `pathLossExponent`를
/// 반드시 실측값으로 보정해야 한다.
class BeaconDistanceEstimator {
  const BeaconDistanceEstimator({
    this.txPower = -59,
    this.pathLossExponent = 2.0,
    this.veryCloseRssiThreshold = -55,
    this.closeRssiThreshold = -67,
    this.mediumRssiThreshold = -80,
    this.farRssiThreshold = -92,
    this.nearDistanceThresholdMeters = 3.0,
    this.mediumDistanceThresholdMeters = 8.0,
    this.zoneHysteresisMeters = 0.75,
  })  : assert(pathLossExponent > 0, 'pathLossExponent must be greater than 0'),
        assert(
          nearDistanceThresholdMeters > 0,
          'nearDistanceThresholdMeters must be greater than 0',
        ),
        assert(
          mediumDistanceThresholdMeters > nearDistanceThresholdMeters,
          'mediumDistanceThresholdMeters must be greater than near threshold',
        ),
        assert(
          zoneHysteresisMeters >= 0,
          'zoneHysteresisMeters must be zero or greater',
        );

  /// 기준 거리 1m에서 측정되는 RSSI 기준값이다.
  ///
  /// 제조사 또는 설치 위치별로 달라질 수 있으므로 고정된 정답값으로 보면 안 된다.
  final int txPower;

  /// RSSI가 거리 증가에 따라 약해지는 정도를 나타내는 환경 계수이다.
  ///
  /// 개방 공간과 실내 복도, 벽이 있는 공간에서 값이 달라질 수 있다.
  final double pathLossExponent;

  /// 이 값 이상이면 [BeaconSignalLevel.veryClose]로 분류한다.
  final int veryCloseRssiThreshold;

  /// 이 값 이상이면 [BeaconSignalLevel.close]로 분류한다.
  final int closeRssiThreshold;

  /// 이 값 이상이면 [BeaconSignalLevel.medium]으로 분류한다.
  final int mediumRssiThreshold;

  /// 이 값 이상이면 [BeaconSignalLevel.far]로 분류한다.
  ///
  /// 이 값보다 약한 RSSI는 [BeaconSignalLevel.lost]로 분류한다.
  final int farRssiThreshold;

  /// `near` 구간의 거리 상한이다.
  ///
  /// 이 값은 현장 보정 전 앱 안내용 초기 구간값이다.
  final double nearDistanceThresholdMeters;

  /// `medium` 구간의 거리 상한이다. 이 값보다 멀면 `far`로 본다.
  final double mediumDistanceThresholdMeters;

  /// 구간 경계 근처에서 값이 오락가락하지 않도록 이전 구간을 유지하는 완충 폭이다.
  final double zoneHysteresisMeters;

  /// RSSI 기반 거리 추정값을 meter 단위로 반환한다.
  ///
  /// RSSI가 0 이상인 값은 BLE 수신 신호로 보기 어려워 추정 불가로 처리한다.
  /// 추정 불가 상황에서는 `BeaconSignal.estimatedDistanceMeters` 계약에 맞춰
  /// 호출자가 null을 저장할 수 있도록 null을 반환한다.
  double? estimateMeters(int rssi) {
    if (!SensorModelValidation.isValidRssi(rssi)) return null;
    return pow(10, (txPower - rssi) / (10 * pathLossExponent)).toDouble();
  }

  /// RSSI 값을 신호 레벨 enum으로 분류한다.
  BeaconSignalLevel classify(int rssi) {
    if (!SensorModelValidation.isValidRssi(rssi)) return BeaconSignalLevel.lost;
    if (rssi >= veryCloseRssiThreshold) return BeaconSignalLevel.veryClose;
    if (rssi >= closeRssiThreshold) return BeaconSignalLevel.close;
    if (rssi >= mediumRssiThreshold) return BeaconSignalLevel.medium;
    if (rssi >= farRssiThreshold) return BeaconSignalLevel.far;
    return BeaconSignalLevel.lost;
  }

  /// RSSI 값을 앱 안내용 거리 구간으로 분류한다.
  ///
  /// `VERY_CLOSE`와 `CLOSE`는 모두 사용자가 안내 지점 근처에 있다고 보고
  /// `near`로 묶는다. `LOST`와 invalid RSSI는 `unknown`으로 둔다.
  BeaconDistanceZone classifyZone(int rssi) {
    return zoneFromSignalLevel(classify(rssi));
  }

  /// meter 단위 추정값을 앱 안내용 거리 구간으로 분류한다.
  BeaconDistanceZone classifyZoneFromMeters(double? estimatedDistanceMeters) {
    final distance = SensorModelValidation.normalizeEstimatedDistanceMeters(
      estimatedDistanceMeters,
      fieldName: 'BeaconDistanceEstimator.estimatedDistanceMeters',
    );
    if (distance == null) return BeaconDistanceZone.unknown;
    if (distance <= nearDistanceThresholdMeters) return BeaconDistanceZone.near;
    if (distance <= mediumDistanceThresholdMeters) {
      return BeaconDistanceZone.medium;
    }
    return BeaconDistanceZone.far;
  }

  /// RSSI에서 meter 추정값, signal level, 앱 안내용 거리 구간을 함께 계산한다.
  BeaconDistanceEstimate estimate(int rssi) {
    final signalLevel = classify(rssi);
    final estimatedDistanceMeters = estimateMeters(rssi);
    final zoneByDistance = classifyZoneFromMeters(estimatedDistanceMeters);
    final zoneBySignal = zoneFromSignalLevel(signalLevel);

    return BeaconDistanceEstimate(
      rssi: SensorModelValidation.isValidRssi(rssi)
          ? rssi
          : SensorModelValidation.minValidRssi,
      signalLevel: signalLevel,
      distanceZone: zoneByDistance == BeaconDistanceZone.unknown
          ? zoneBySignal
          : zoneByDistance,
      estimatedDistanceMeters: estimatedDistanceMeters,
    );
  }

  /// signal level을 앱 안내용 거리 구간으로 변환한다.
  static BeaconDistanceZone zoneFromSignalLevel(BeaconSignalLevel signalLevel) {
    switch (signalLevel) {
      case BeaconSignalLevel.veryClose:
      case BeaconSignalLevel.close:
        return BeaconDistanceZone.near;
      case BeaconSignalLevel.medium:
        return BeaconDistanceZone.medium;
      case BeaconSignalLevel.far:
        return BeaconDistanceZone.far;
      case BeaconSignalLevel.lost:
        return BeaconDistanceZone.unknown;
    }
  }

  /// 이전 구간과 새 후보 구간 사이에서 경계 흔들림을 완화한다.
  ///
  /// 예를 들어 `near`와 `medium` 경계인 3m 부근에서 추정값이 2.9m, 3.1m로
  /// 반복되면 앱 안내가 계속 바뀔 수 있다. 이 메서드는 경계 완충 폭 안에서는
  /// 이전 구간을 유지해 안내 변화가 과도하게 잦아지는 것을 줄인다.
  BeaconDistanceZone stabilizeZone({
    required BeaconDistanceZone previousZone,
    required BeaconDistanceZone candidateZone,
    double? estimatedDistanceMeters,
  }) {
    if (previousZone == BeaconDistanceZone.unknown ||
        candidateZone == BeaconDistanceZone.unknown) {
      return candidateZone;
    }

    final distance = SensorModelValidation.normalizeEstimatedDistanceMeters(
      estimatedDistanceMeters,
      fieldName: 'BeaconDistanceEstimator.estimatedDistanceMeters',
    );
    if (distance == null) return candidateZone;

    if (_isNearMediumBoundary(distance) &&
        _isNearMediumPair(previousZone, candidateZone)) {
      return previousZone;
    }
    if (_isMediumFarBoundary(distance) &&
        _isMediumFarPair(previousZone, candidateZone)) {
      return previousZone;
    }
    return candidateZone;
  }

  /// smoothing된 RSSI를 기반으로 [BeaconSignal]을 생성한다.
  ///
  /// 앱 UI와 무관한 패키지 내부 편의 메서드이며, 실제 BLE 스캔 결과를
  /// 모델 계약에 맞춰 변환하는 경계를 명확히 하기 위한 skeleton이다.
  BeaconSignal buildSignal({
    required String beaconId,
    required int rssi,
    required DateTime lastDetectedAt,
    double? estimatedDistanceMeters,
  }) {
    final normalizedBeaconId =
        SensorModelValidation.normalizeBeaconId(beaconId);
    final safeRssi = SensorModelValidation.isValidRssi(rssi)
        ? rssi
        : SensorModelValidation.minValidRssi;
    final distance = SensorModelValidation.normalizeEstimatedDistanceMeters(
          estimatedDistanceMeters,
          fieldName: 'BeaconDistanceEstimator.estimatedDistanceMeters',
        ) ??
        estimateMeters(safeRssi);

    return BeaconSignal(
      beaconId: normalizedBeaconId,
      rssi: safeRssi,
      estimatedDistanceMeters: distance,
      signalLevel: classify(safeRssi),
      lastDetectedAt: lastDetectedAt,
    );
  }

  bool _isNearMediumBoundary(double distance) {
    return (distance - nearDistanceThresholdMeters).abs() <=
        zoneHysteresisMeters;
  }

  bool _isMediumFarBoundary(double distance) {
    return (distance - mediumDistanceThresholdMeters).abs() <=
        zoneHysteresisMeters;
  }

  bool _isNearMediumPair(
      BeaconDistanceZone previous, BeaconDistanceZone candidate) {
    return (previous == BeaconDistanceZone.near &&
            candidate == BeaconDistanceZone.medium) ||
        (previous == BeaconDistanceZone.medium &&
            candidate == BeaconDistanceZone.near);
  }

  bool _isMediumFarPair(
      BeaconDistanceZone previous, BeaconDistanceZone candidate) {
    return (previous == BeaconDistanceZone.medium &&
            candidate == BeaconDistanceZone.far) ||
        (previous == BeaconDistanceZone.far &&
            candidate == BeaconDistanceZone.medium);
  }
}

/// 최근 RSSI 샘플의 이동 평균을 계산하는 단순 smoothing helper이다.
///
/// 이 helper는 현장 검증값을 가장하지 않는다. BLE RSSI의 순간 튐을 완화하기
/// 위한 패키지 내부 기본 구조이며, window 크기는 테스트와 현장 측정 후 조정한다.
class RssiMovingAverageSmoother {
  RssiMovingAverageSmoother({
    this.windowSize = 5,
    this.maxSingleSampleDelta = 10,
    this.lostResetThreshold = 3,
  })  : assert(windowSize > 0, 'windowSize must be greater than 0'),
        assert(
          maxSingleSampleDelta > 0,
          'maxSingleSampleDelta must be greater than 0',
        ),
        assert(
          lostResetThreshold > 0,
          'lostResetThreshold must be greater than 0',
        );

  final int windowSize;

  /// 한 번의 RSSI 샘플이 현재 smoothing 값에서 허용되는 최대 변화 폭이다.
  ///
  /// BLE RSSI는 순간적으로 크게 튈 수 있으므로, 단일 샘플이 안내 구간을
  /// 즉시 바꾸지 않도록 현재 평균 근처로 보정한다.
  final int maxSingleSampleDelta;

  /// invalid RSSI 또는 신호 끊김이 몇 번 연속 발생하면 window를 초기화할지 정한다.
  final int lostResetThreshold;

  final Queue<int> _samples = Queue<int>();
  int _consecutiveLostSamples = 0;

  /// 현재 smoothing에 사용 중인 샘플 목록이다.
  List<int> get samples => List.unmodifiable(_samples);

  /// 현재 샘플이 없는지 여부이다.
  bool get isEmpty => _samples.isEmpty;

  /// 연속으로 기록된 invalid/missing RSSI 횟수이다.
  int get consecutiveLostSamples => _consecutiveLostSamples;

  /// 모든 샘플과 연속 신호 끊김 카운터를 제거한다.
  void reset() {
    _samples.clear();
    _consecutiveLostSamples = 0;
  }

  /// 새 RSSI 값을 추가하고 이동 평균 RSSI를 반환한다.
  ///
  /// invalid RSSI는 정상 샘플로 넣지 않는다. 대신 연속 신호 끊김으로 기록하고,
  /// [lostResetThreshold]에 도달하면 기존 평균을 초기화해 오래된 RSSI가 계속
  /// 남아 있는 문제를 막는다.
  int addSample(int rssi) {
    if (!SensorModelValidation.isValidRssi(rssi)) {
      return recordSignalLost();
    }

    _consecutiveLostSamples = 0;
    final boundedRssi = _boundOutlier(rssi);

    _samples.addLast(boundedRssi);
    while (_samples.length > windowSize) {
      _samples.removeFirst();
    }
    return smoothedRssi;
  }

  /// 스캔 결과가 없거나 RSSI를 신뢰할 수 없는 경우 호출하는 helper이다.
  ///
  /// 신호가 한두 번만 비는 상황에서는 마지막 평균을 유지하되, 여러 번 연속
  /// 비면 window를 비워서 다음 계산이 `LOST/UNKNOWN`으로 이어지게 한다.
  int recordSignalLost() {
    _consecutiveLostSamples += 1;
    if (_consecutiveLostSamples >= lostResetThreshold) {
      reset();
    }
    return smoothedRssi;
  }

  int _boundOutlier(int rssi) {
    if (_samples.isEmpty) return rssi;

    final current = smoothedRssi;
    final delta = rssi - current;
    if (delta.abs() <= maxSingleSampleDelta) {
      return rssi;
    }

    if (delta > 0) {
      return current + maxSingleSampleDelta;
    }
    return current - maxSingleSampleDelta;
  }

  /// 현재 window의 평균 RSSI이다.
  ///
  /// RSSI는 정수 계약이므로 반올림한 정수로 반환한다. 샘플이 없을 때는
  /// BLE 신호로 보기 어려운 0을 반환하여 추정 불가/LOST 처리와 연결한다.
  int get smoothedRssi {
    if (_samples.isEmpty) return 0;
    final sum =
        _samples.fold<int>(0, (previous, current) => previous + current);
    return (sum / _samples.length).round();
  }
}

class BeaconRssiCalibrationSample {
  const BeaconRssiCalibrationSample({
    required this.distanceMeters,
    required this.rssi,
  })  : assert(distanceMeters > 0, 'distanceMeters must be greater than 0'),
        assert(
          rssi >= SensorModelValidation.minValidRssi &&
              rssi <= SensorModelValidation.maxValidRssi,
          'rssi must be between -127 and -1',
        );

  final double distanceMeters;
  final int rssi;
}

class BeaconRssiCalibration {
  const BeaconRssiCalibration({
    required this.txPower,
    required this.pathLossExponent,
    required this.samples,
  });

  final int txPower;
  final double pathLossExponent;
  final List<BeaconRssiCalibrationSample> samples;

  factory BeaconRssiCalibration.fromSamples(
    Iterable<BeaconRssiCalibrationSample> samples, {
    double fallbackPathLossExponent = 2.0,
  }) {
    final values = samples.toList(growable: false);
    if (values.isEmpty) {
      throw ArgumentError('At least one calibration sample is required.');
    }
    if (fallbackPathLossExponent <= 0) {
      throw ArgumentError('fallbackPathLossExponent must be greater than 0.');
    }

    if (values.length == 1) {
      final sample = values.single;
      return BeaconRssiCalibration(
        txPower: _txPowerFor(sample, fallbackPathLossExponent).round(),
        pathLossExponent: fallbackPathLossExponent,
        samples: values,
      );
    }

    final xs = values.map((sample) => _log10(sample.distanceMeters)).toList();
    final ys = values.map((sample) => sample.rssi.toDouble()).toList();
    final meanX = xs.reduce((a, b) => a + b) / xs.length;
    final meanY = ys.reduce((a, b) => a + b) / ys.length;

    var covariance = 0.0;
    var variance = 0.0;
    for (var index = 0; index < values.length; index += 1) {
      final dx = xs[index] - meanX;
      covariance += dx * (ys[index] - meanY);
      variance += dx * dx;
    }

    if (variance == 0) {
      final averageTxPower = values
              .map((sample) => _txPowerFor(sample, fallbackPathLossExponent))
              .reduce((a, b) => a + b) /
          values.length;
      return BeaconRssiCalibration(
        txPower: averageTxPower.round(),
        pathLossExponent: fallbackPathLossExponent,
        samples: values,
      );
    }

    final slope = covariance / variance;
    final pathLossExponent = (-slope / 10).clamp(1.2, 4.5).toDouble();
    final intercept = meanY - (slope * meanX);

    return BeaconRssiCalibration(
      txPower: intercept.round(),
      pathLossExponent: pathLossExponent,
      samples: values,
    );
  }

  BeaconDistanceEstimator toEstimator() {
    return BeaconDistanceEstimator(
      txPower: txPower,
      pathLossExponent: pathLossExponent,
    );
  }

  static double _txPowerFor(
    BeaconRssiCalibrationSample sample,
    double pathLossExponent,
  ) {
    return sample.rssi +
        (10 * pathLossExponent * _log10(sample.distanceMeters));
  }

  static double _log10(double value) => log(value) / ln10;
}
