import 'dart:collection';

import 'beacon_signal.dart';
import 'direction_sensor.dart';
import 'sensor_model_validation.dart';

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


/// Passenger App이 소비할 수 있는 비콘 근접 이벤트 종류이다.
///
/// 이 enum은 실제 BLE 스캔이나 앱 UI 동작을 수행하지 않고, 센서 패키지가
/// 앱/로그/오디오 cue 계층에 넘길 수 있는 이벤트 이름만 고정한다.
enum ProximityEventType { beaconNear, beaconLost, approachingStop, leavingStop }

extension ProximityEventTypeJson on ProximityEventType {
  String toJsonValue() {
    switch (this) {
      case ProximityEventType.beaconNear:
        return 'BEACON_NEAR';
      case ProximityEventType.beaconLost:
        return 'BEACON_LOST';
      case ProximityEventType.approachingStop:
        return 'APPROACHING_STOP';
      case ProximityEventType.leavingStop:
        return 'LEAVING_STOP';
    }
  }

  static ProximityEventType fromJsonValue(String value) {
    switch (value) {
      case 'BEACON_NEAR':
        return ProximityEventType.beaconNear;
      case 'BEACON_LOST':
        return ProximityEventType.beaconLost;
      case 'APPROACHING_STOP':
        return ProximityEventType.approachingStop;
      case 'LEAVING_STOP':
        return ProximityEventType.leavingStop;
      default:
        throw ArgumentError('Unknown ProximityEventType JSON value: $value');
    }
  }
}

/// 비콘 신호와 선택적인 방향 정보를 앱이 소비할 수 있는 근접 이벤트로 묶는다.
///
/// V2 섹션 1 기준으로 앱이 필요한 `beaconId`, `rssi`,
/// `estimatedDistanceMeters`, `signalLevel`, `direction`, `timestamp`를 한 모델에
/// 고정한다. 실제 stream 변환은 `ProximityEventStreamAdapter`에서 수행한다.
class ProximityEvent {
  const ProximityEvent({
    required this.eventType,
    required this.beaconId,
    required this.signalLevel,
    required this.timestamp,
    this.rssi,
    this.estimatedDistanceMeters,
    this.direction,
    this.metadata = const {},
  })  : assert(beaconId.length > 0, 'beaconId must not be empty'),
        assert(
          rssi == null ||
              (rssi >= SensorModelValidation.minValidRssi &&
                  rssi <= SensorModelValidation.maxValidRssi),
          'rssi must be null or between -127 and -1',
        ),
        assert(
          estimatedDistanceMeters == null || estimatedDistanceMeters >= 0,
          'estimatedDistanceMeters must be non-negative or null',
        );

  /// 앱 또는 로그에서 구분할 근접 이벤트 종류이다.
  final ProximityEventType eventType;

  /// 이벤트 기준이 된 비콘 ID이다.
  final String beaconId;

  /// 이벤트 기준 RSSI 값이다. 비콘 신호가 완전히 없으면 null일 수 있다.
  final int? rssi;

  /// RSSI 기반 추정 거리이다. 추정 불가하거나 신호 상실이면 null을 유지한다.
  final double? estimatedDistanceMeters;

  /// 이벤트 생성 시점의 비콘 신호 단계이다.
  final BeaconSignalLevel signalLevel;

  /// 선택적인 스마트폰 방향/나침반 값이다. 방향 센서가 없으면 null이다.
  final DirectionReading? direction;

  /// 이벤트 생성 시각이다.
  final DateTime timestamp;

  /// 후속 섹션에서 fixture/replay/debug 정보를 넣기 위한 선택 필드이다.
  final Map<String, Object?> metadata;

  bool get isLost => eventType == ProximityEventType.beaconLost;

  ProximityEvent copyWith({
    ProximityEventType? eventType,
    String? beaconId,
    int? rssi,
    bool clearRssi = false,
    double? estimatedDistanceMeters,
    bool clearEstimatedDistanceMeters = false,
    BeaconSignalLevel? signalLevel,
    DirectionReading? direction,
    bool clearDirection = false,
    DateTime? timestamp,
    Map<String, Object?>? metadata,
  }) {
    return ProximityEvent(
      eventType: eventType ?? this.eventType,
      beaconId: beaconId ?? this.beaconId,
      rssi: clearRssi ? null : rssi ?? this.rssi,
      estimatedDistanceMeters: clearEstimatedDistanceMeters
          ? null
          : estimatedDistanceMeters ?? this.estimatedDistanceMeters,
      signalLevel: signalLevel ?? this.signalLevel,
      direction: clearDirection ? null : direction ?? this.direction,
      timestamp: timestamp ?? this.timestamp,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, Object?> toJson() => {
        'eventType': eventType.toJsonValue(),
        'beaconId': beaconId,
        'rssi': rssi,
        'estimatedDistanceMeters': estimatedDistanceMeters,
        'signalLevel': signalLevel.toJsonValue(),
        'direction': direction?.toJson(),
        'timestamp': timestamp.toIso8601String(),
        'metadata': metadata,
      };

  factory ProximityEvent.fromJson(Map<String, Object?> json) {
    final eventType = json['eventType'];
    final beaconId = json['beaconId'];
    final rssi = json['rssi'];
    final estimatedDistanceMeters = json['estimatedDistanceMeters'];
    final signalLevel = json['signalLevel'];
    final direction = json['direction'];
    final timestamp = json['timestamp'];
    final metadata = json['metadata'];

    if (eventType is! String) {
      throw ArgumentError('ProximityEvent.eventType must be a string.');
    }
    if (beaconId != null && beaconId is! String) {
      throw ArgumentError('ProximityEvent.beaconId must be a string or null.');
    }
    if (signalLevel is! String) {
      throw ArgumentError('ProximityEvent.signalLevel must be a string.');
    }
    if (direction != null && direction is! Map) {
      throw ArgumentError('ProximityEvent.direction must be an object or null.');
    }
    if (metadata != null && metadata is! Map) {
      throw ArgumentError('ProximityEvent.metadata must be an object or null.');
    }

    return ProximityEvent(
      eventType: ProximityEventTypeJson.fromJsonValue(eventType),
      beaconId: SensorModelValidation.normalizeBeaconId(beaconId as String?),
      rssi: rssi == null
          ? null
          : SensorModelValidation.requireValidRssi(
              rssi,
              fieldName: 'ProximityEvent.rssi',
            ),
      estimatedDistanceMeters:
          SensorModelValidation.normalizeEstimatedDistanceMeters(
        estimatedDistanceMeters,
        fieldName: 'ProximityEvent.estimatedDistanceMeters',
      ),
      signalLevel: BeaconSignalLevelJson.fromJsonValue(signalLevel),
      direction: direction == null
          ? null
          : DirectionReading.fromJson(Map<String, Object?>.from(direction as Map)),
      timestamp: SensorModelValidation.requireIsoTimestamp(
        timestamp,
        fieldName: 'ProximityEvent.timestamp',
      ),
      metadata: metadata == null
          ? const {}
          : Map<String, Object?>.from(metadata as Map),
    );
  }

  /// [BeaconSignal]을 근접 이벤트 payload로 감싸는 편의 생성자이다.
  factory ProximityEvent.fromBeaconSignal(
    BeaconSignal signal, {
    required ProximityEventType eventType,
    DirectionReading? direction,
    DateTime? timestamp,
    Map<String, Object?> metadata = const {},
  }) {
    return ProximityEvent(
      eventType: eventType,
      beaconId: signal.beaconId,
      rssi: signal.rssi,
      estimatedDistanceMeters: signal.estimatedDistanceMeters,
      signalLevel: signal.signalLevel,
      direction: direction,
      timestamp: timestamp ?? signal.lastDetectedAt,
      metadata: metadata,
    );
  }

  /// 비콘 신호 상실 이벤트를 명시적으로 만들 때 사용한다.
  factory ProximityEvent.beaconLost({
    required String beaconId,
    DirectionReading? direction,
    DateTime? timestamp,
    Map<String, Object?> metadata = const {},
  }) {
    return ProximityEvent(
      eventType: ProximityEventType.beaconLost,
      beaconId: SensorModelValidation.normalizeBeaconId(beaconId),
      rssi: null,
      estimatedDistanceMeters: null,
      signalLevel: BeaconSignalLevel.lost,
      direction: direction,
      timestamp: timestamp ?? DateTime.now(),
      metadata: metadata,
    );
  }
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
