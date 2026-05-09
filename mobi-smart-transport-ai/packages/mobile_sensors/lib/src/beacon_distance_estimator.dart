import 'dart:collection';
import 'dart:math';

import 'beacon_signal.dart';

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
  }) : assert(pathLossExponent > 0, 'pathLossExponent must be greater than 0');

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

  /// RSSI 기반 거리 추정값을 meter 단위로 반환한다.
  ///
  /// RSSI가 0 이상인 값은 BLE 수신 신호로 보기 어려워 추정 불가로 처리한다.
  /// 추정 불가 상황에서는 `BeaconSignal.estimatedDistanceMeters` 계약에 맞춰
  /// 호출자가 null을 저장할 수 있도록 null을 반환한다.
  double? estimateMeters(int rssi) {
    if (rssi >= 0) return null;
    return pow(10, (txPower - rssi) / (10 * pathLossExponent)).toDouble();
  }

  /// RSSI 값을 신호 레벨 enum으로 분류한다.
  BeaconSignalLevel classify(int rssi) {
    if (rssi >= 0) return BeaconSignalLevel.lost;
    if (rssi >= veryCloseRssiThreshold) return BeaconSignalLevel.veryClose;
    if (rssi >= closeRssiThreshold) return BeaconSignalLevel.close;
    if (rssi >= mediumRssiThreshold) return BeaconSignalLevel.medium;
    if (rssi >= farRssiThreshold) return BeaconSignalLevel.far;
    return BeaconSignalLevel.lost;
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
    final distance = estimatedDistanceMeters ?? estimateMeters(rssi);
    return BeaconSignal(
      beaconId: beaconId,
      rssi: rssi,
      estimatedDistanceMeters: distance,
      signalLevel: classify(rssi),
      lastDetectedAt: lastDetectedAt,
    );
  }
}

/// 최근 RSSI 샘플의 이동 평균을 계산하는 단순 smoothing helper이다.
///
/// 이 helper는 현장 검증값을 가장하지 않는다. BLE RSSI의 순간 튐을 완화하기
/// 위한 패키지 내부 기본 구조이며, window 크기는 테스트와 현장 측정 후 조정한다.
class RssiMovingAverageSmoother {
  RssiMovingAverageSmoother({this.windowSize = 5})
      : assert(windowSize > 0, 'windowSize must be greater than 0');

  final int windowSize;
  final Queue<int> _samples = Queue<int>();

  /// 현재 smoothing에 사용 중인 샘플 목록이다.
  List<int> get samples => List.unmodifiable(_samples);

  /// 현재 샘플이 없는지 여부이다.
  bool get isEmpty => _samples.isEmpty;

  /// 모든 샘플을 제거한다.
  void reset() {
    _samples.clear();
  }

  /// 새 RSSI 값을 추가하고 이동 평균 RSSI를 반환한다.
  int addSample(int rssi) {
    _samples.addLast(rssi);
    while (_samples.length > windowSize) {
      _samples.removeFirst();
    }
    return smoothedRssi;
  }

  /// 현재 window의 평균 RSSI이다.
  ///
  /// RSSI는 정수 계약이므로 반올림한 정수로 반환한다. 샘플이 없을 때는
  /// BLE 신호로 보기 어려운 0을 반환하여 추정 불가/LOST 처리와 연결한다.
  int get smoothedRssi {
    if (_samples.isEmpty) return 0;
    final sum = _samples.fold<int>(0, (previous, current) => previous + current);
    return (sum / _samples.length).round();
  }
}
