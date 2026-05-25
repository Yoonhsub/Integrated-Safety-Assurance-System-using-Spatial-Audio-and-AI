import 'beacon_distance_estimator.dart';
import 'beacon_proximity_tracker.dart';
import 'beacon_scanner.dart';
import 'beacon_signal.dart';
import 'direction_sensor.dart';

/// 특정 [BeaconSignal]에 대응되는 방향 센서값을 선택적으로 제공한다.
///
/// Passenger App은 화면/UI를 직접 수정하지 않고도 이 callback을 통해 현재
/// 방향값을 proximity event payload에 붙일 수 있다.
typedef ProximityDirectionProvider = DirectionReading? Function(BeaconSignal signal);

/// BLE beacon signal stream을 Passenger App이 소비할 수 있는 proximity event
/// stream으로 변환하는 adapter이다.
///
/// 이 클래스는 앱 화면, 권한 요청 UI, 실제 TTS 호출을 구현하지 않는다.
/// [BeaconScanner]가 내보내는 [BeaconSignal]을 받아 V2 섹션 5 기준 이벤트인
/// `BEACON_NEAR`, `BEACON_LOST`, `APPROACHING_STOP`, `LEAVING_STOP`으로 변환한다.
class ProximityEventStreamAdapter {
  ProximityEventStreamAdapter({
    required this.scanner,
    BeaconProximityTracker? tracker,
  }) : tracker = tracker ?? BeaconProximityTracker();

  /// BLE scan source이다. 실제 scanner 또는 [MockBeaconScanner]를 주입할 수 있다.
  final BeaconScanner scanner;

  /// 이전 신호와 현재 신호 사이의 접근/이탈 추세를 계산한다.
  final BeaconProximityTracker tracker;

  /// scanner signal stream을 proximity event stream으로 변환한다.
  ///
  /// [targetBeaconId]가 있으면 scanner 단계에서 해당 beacon만 통과시킨다.
  /// [directionProvider]는 방향 센서값을 event payload에 붙이고 싶을 때만 사용한다.
  Stream<ProximityEvent> watch({
    String? targetBeaconId,
    ProximityDirectionProvider? directionProvider,
  }) async* {
    await for (final signal in scanner.scan(targetBeaconId: targetBeaconId)) {
      final direction = directionProvider?.call(signal);
      for (final event in eventsForSignal(signal, direction: direction)) {
        yield event;
      }
    }
  }

  /// 단일 [BeaconSignal]을 0개 이상의 [ProximityEvent]로 변환한다.
  ///
  /// 한 signal에서 `BEACON_NEAR`와 `APPROACHING_STOP`처럼 여러 이벤트가 동시에
  /// 나올 수 있다. 앱은 eventType과 metadata를 보고 필요한 안내만 선택한다.
  Iterable<ProximityEvent> eventsForSignal(
    BeaconSignal signal, {
    DirectionReading? direction,
    DateTime? now,
  }) sync* {
    final referenceTime = now ?? signal.lastDetectedAt;

    if (signal.isLost) {
      tracker.resetBeacon(signal.beaconId);
      yield createLostEvent(
        beaconId: signal.beaconId,
        direction: direction,
        timestamp: referenceTime,
        metadata: const {'source': 'mobile_sensors'},
      );
      return;
    }

    final snapshot = tracker.addSignal(signal, now: referenceTime);
    final distanceZone = BeaconDistanceEstimator.zoneFromSignalLevel(
      signal.signalLevel,
    );

    if (distanceZone == BeaconDistanceZone.near) {
      yield _fromSignal(
        signal,
        eventType: ProximityEventType.beaconNear,
        direction: direction,
        timestamp: referenceTime,
        snapshot: snapshot,
        distanceZone: distanceZone,
      );
    }

    if (snapshot.trend == BeaconProximityTrend.approaching) {
      yield _fromSignal(
        signal,
        eventType: ProximityEventType.approachingStop,
        direction: direction,
        timestamp: referenceTime,
        snapshot: snapshot,
        distanceZone: distanceZone,
      );
    }

    if (snapshot.trend == BeaconProximityTrend.movingAway) {
      yield _fromSignal(
        signal,
        eventType: ProximityEventType.leavingStop,
        direction: direction,
        timestamp: referenceTime,
        snapshot: snapshot,
        distanceZone: distanceZone,
      );
    }
  }

  /// scan stream 자체가 끊기거나 앱 lifecycle에서 스캔 중단을 감지했을 때 호출할 수
  /// 있는 명시적인 lost event factory이다.
  ProximityEvent createLostEvent({
    required String beaconId,
    DirectionReading? direction,
    DateTime? timestamp,
    Map<String, Object?> metadata = const {},
  }) {
    return ProximityEvent.beaconLost(
      beaconId: beaconId,
      direction: direction,
      timestamp: timestamp,
      metadata: {
        'source': 'mobile_sensors',
        'distanceZone': BeaconDistanceZone.unknown.toJsonValue(),
        'trend': BeaconProximityTrend.unknown.toJsonValue(),
        ...metadata,
      },
    );
  }

  ProximityEvent _fromSignal(
    BeaconSignal signal, {
    required ProximityEventType eventType,
    required DateTime timestamp,
    required BeaconProximitySnapshot snapshot,
    required BeaconDistanceZone distanceZone,
    DirectionReading? direction,
  }) {
    return ProximityEvent.fromBeaconSignal(
      signal,
      eventType: eventType,
      direction: direction,
      timestamp: timestamp,
      metadata: {
        'source': 'mobile_sensors',
        'distanceZone': distanceZone.toJsonValue(),
        'trend': snapshot.trend.toJsonValue(),
        'isStale': snapshot.isStale,
        'rssiDelta': snapshot.rssiDelta,
        'distanceDeltaMeters': snapshot.distanceDeltaMeters,
      },
    );
  }
}
