import 'dart:collection';

import 'beacon_signal.dart';

/// RSSI/거리 변화로부터 사용자가 비콘에 가까워지는지, 멀어지는지 판단한다.
///
/// BLE RSSI는 순간적으로 크게 튈 수 있으므로 이 클래스의 판단 결과는
/// 정밀 위치값이 아니라 골전도 이어폰 안내나 로그 검증에서 사용할 수 있는
/// 접근 추세 힌트로만 사용한다.
enum BeaconProximityTrend { approaching, movingAway, stable, unknown }

extension BeaconProximityTrendJson on BeaconProximityTrend {
  String toJsonValue() {
    switch (this) {
      case BeaconProximityTrend.approaching:
        return 'APPROACHING';
      case BeaconProximityTrend.movingAway:
        return 'MOVING_AWAY';
      case BeaconProximityTrend.stable:
        return 'STABLE';
      case BeaconProximityTrend.unknown:
        return 'UNKNOWN';
    }
  }
}

/// 비콘 접근 추세 판단 결과이다.
class BeaconProximitySnapshot {
  const BeaconProximitySnapshot({
    required this.beaconId,
    required this.trend,
    required this.currentSignal,
    required this.updatedAt,
    this.previousSignal,
    this.distanceDeltaMeters,
    this.rssiDelta,
    this.isStale = false,
  });

  final String beaconId;
  final BeaconProximityTrend trend;
  final BeaconSignal currentSignal;
  final BeaconSignal? previousSignal;
  final double? distanceDeltaMeters;
  final int? rssiDelta;
  final bool isStale;
  final DateTime updatedAt;

  bool get isApproaching => trend == BeaconProximityTrend.approaching;
  bool get isMovingAway => trend == BeaconProximityTrend.movingAway;
  bool get isStable => trend == BeaconProximityTrend.stable;

  Map<String, Object?> toJson() => {
        'beaconId': beaconId,
        'trend': trend.toJsonValue(),
        'currentSignal': currentSignal.toJson(),
        'previousSignal': previousSignal?.toJson(),
        'distanceDeltaMeters': distanceDeltaMeters,
        'rssiDelta': rssiDelta,
        'isStale': isStale,
        'updatedAt': updatedAt.toIso8601String(),
      };
}

/// 비콘별 최근 [BeaconSignal]을 저장하고 가까워짐/멀어짐 추세를 계산한다.
class BeaconProximityTracker {
  BeaconProximityTracker({
    this.historySize = 2,
    this.distanceStableThresholdMeters = 0.4,
    this.rssiStableThreshold = 3,
    this.maxSignalAge = const Duration(seconds: 5),
  })  : assert(historySize >= 2, 'historySize must be at least 2'),
        assert(
          distanceStableThresholdMeters >= 0,
          'distanceStableThresholdMeters must be zero or greater',
        ),
        assert(rssiStableThreshold >= 0, 'rssiStableThreshold must be zero or greater');

  /// 비콘별로 보관할 최근 signal 개수이다.
  final int historySize;

  /// 거리 변화가 이 값보다 작으면 stable로 본다.
  final double distanceStableThresholdMeters;

  /// 거리값이 없을 때 RSSI 변화량이 이 값보다 작으면 stable로 본다.
  final int rssiStableThreshold;

  /// 이 시간보다 오래된 signal은 stale로 보고 trend를 unknown으로 둔다.
  final Duration maxSignalAge;

  final Map<String, Queue<BeaconSignal>> _historyByBeaconId = {};

  /// 현재 tracker가 알고 있는 beacon id 목록이다.
  Iterable<String> get trackedBeaconIds => _historyByBeaconId.keys;

  /// 모든 비콘의 history를 지운다.
  void reset() {
    _historyByBeaconId.clear();
  }

  /// 특정 비콘의 history만 지운다.
  void resetBeacon(String beaconId) {
    _historyByBeaconId.remove(beaconId);
  }

  /// 새 signal을 추가하고 접근 추세 snapshot을 반환한다.
  BeaconProximitySnapshot addSignal(BeaconSignal signal, {DateTime? now}) {
    final referenceTime = now ?? DateTime.now();
    final history = _historyByBeaconId.putIfAbsent(
      signal.beaconId,
      () => Queue<BeaconSignal>(),
    );
    final previous = history.isEmpty ? null : history.last;

    history.addLast(signal);
    while (history.length > historySize) {
      history.removeFirst();
    }

    final isStale = !signal.wasDetectedWithin(maxSignalAge, now: referenceTime);
    final trend = isStale || signal.isLost
        ? BeaconProximityTrend.unknown
        : _calculateTrend(previous, signal);

    return BeaconProximitySnapshot(
      beaconId: signal.beaconId,
      trend: trend,
      currentSignal: signal,
      previousSignal: previous,
      distanceDeltaMeters: _distanceDelta(previous, signal),
      rssiDelta: previous == null ? null : signal.rssi - previous.rssi,
      isStale: isStale,
      updatedAt: referenceTime,
    );
  }

  BeaconProximityTrend _calculateTrend(
    BeaconSignal? previous,
    BeaconSignal current,
  ) {
    if (previous == null || previous.isLost) {
      return BeaconProximityTrend.unknown;
    }

    final distanceDelta = _distanceDelta(previous, current);
    if (distanceDelta != null) {
      if (distanceDelta.abs() <= distanceStableThresholdMeters) {
        return BeaconProximityTrend.stable;
      }
      return distanceDelta < 0
          ? BeaconProximityTrend.approaching
          : BeaconProximityTrend.movingAway;
    }

    final rssiDelta = current.rssi - previous.rssi;
    if (rssiDelta.abs() <= rssiStableThreshold) {
      return BeaconProximityTrend.stable;
    }
    return rssiDelta > 0
        ? BeaconProximityTrend.approaching
        : BeaconProximityTrend.movingAway;
  }

  double? _distanceDelta(BeaconSignal? previous, BeaconSignal current) {
    final previousDistance = previous?.estimatedDistanceMeters;
    final currentDistance = current.estimatedDistanceMeters;
    if (previousDistance == null || currentDistance == null) {
      return null;
    }
    return currentDistance - previousDistance;
  }
}
