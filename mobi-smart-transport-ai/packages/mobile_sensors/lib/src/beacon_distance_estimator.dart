import 'dart:math';

import 'beacon_signal.dart';

class BeaconDistanceEstimator {
  const BeaconDistanceEstimator({this.txPower = -59, this.pathLossExponent = 2.0});

  final int txPower;
  final double pathLossExponent;

  double estimateMeters(int rssi) {
    // RSSI 거리 추정의 초기 공식. 실제 현장 보정은 안준환 담당 구현 섹션에서 수행.
    return pow(10, (txPower - rssi) / (10 * pathLossExponent)).toDouble();
  }

  BeaconSignalLevel classify(int rssi) {
    if (rssi >= -55) return BeaconSignalLevel.veryClose;
    if (rssi >= -67) return BeaconSignalLevel.close;
    if (rssi >= -80) return BeaconSignalLevel.medium;
    if (rssi >= -92) return BeaconSignalLevel.far;
    return BeaconSignalLevel.lost;
  }
}
