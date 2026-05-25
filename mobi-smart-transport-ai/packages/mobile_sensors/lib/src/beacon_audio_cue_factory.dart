import 'beacon_proximity_tracker.dart';
import 'beacon_signal.dart';
import 'bone_conduction_audio_cue.dart';

/// 비콘 신호와 접근 추세를 골전도 이어폰 안내 cue로 변환하는 factory이다.
///
/// 이 클래스는 실제 TTS 재생, 블루투스 이어폰 연결, HRTF/3D 공간음향
/// 렌더링을 수행하지 않는다. Flutter 앱 또는 오디오 모듈이 소비할 수 있는
/// [BoneConductionAudioCue] 데이터만 생성한다.
class BeaconAudioCueFactory {
  const BeaconAudioCueFactory({
    this.defaultLostRssi = -127,
  });

  /// 비콘 신호를 잃었을 때 사용할 RSSI placeholder 값이다.
  final int defaultLostRssi;


  /// 단일 [ProximityEvent]를 안내 cue로 변환한다.
  ///
  /// V2 섹션 7 기준으로 앱이 이미 생성한 sensor event를 TTS/오디오 모듈이
  /// 소비할 수 있는 payload로 바꾼다. 실제 소리 재생은 수행하지 않는다.
  BoneConductionAudioCue createCueForEvent(
    ProximityEvent event, {
    DateTime? createdAt,
  }) {
    return BoneConductionAudioCue.fromProximityEvent(
      event,
      createdAt: createdAt,
    );
  }

  /// 알 수 없는 외부 event 이름을 앱이 다룰 수 있는 안전한 fallback cue로 바꾼다.
  ///
  /// `ProximityEventType` 계약에 없는 `BUS_APPROACHING`, `OBSTACLE_DETECTED`
  /// 같은 이름은 이 패키지에서 enum으로 임의 확장하지 않는다. 대신 앱/통합 테스트가
  /// 문자열 event를 받았을 때 crash 없이 일반 경고 payload로 처리할 수 있게 한다.
  BoneConductionAudioCue createFallbackCueForUnknownEvent(
    String eventTypeName, {
    required String beaconId,
    DateTime? createdAt,
  }) {
    final timestamp = createdAt ?? DateTime.now();
    final normalizedEventName = eventTypeName.trim().isEmpty
        ? 'UNKNOWN_EVENT'
        : eventTypeName.trim().toUpperCase();

    return BoneConductionAudioCue(
      cueId: 'event-${normalizedEventName.toLowerCase()}-${beaconId}-${timestamp.millisecondsSinceEpoch}',
      beaconId: beaconId,
      message: '확인되지 않은 센서 이벤트입니다. 주변을 확인하세요.',
      signalLevel: BeaconSignalLevel.lost,
      urgency: BoneConductionCueUrgency.high,
      repeatIntervalMs: 2000,
      createdAt: timestamp,
      shouldRepeat: true,
    ).copyWith(
      clearSourceEventType: true,
      clearEstimatedDistanceMeters: true,
      clearProximityTrend: true,
    );
  }

  /// 같은 event가 짧은 시간 안에 반복될 때 앱이 중복 안내를 억제해도 되는지 판단한다.
  ///
  /// critical cue는 안전 안내 누락을 막기 위해 억제하지 않는다. 이 함수는 실제 timer나
  /// audio queue를 실행하지 않고, Passenger App 또는 오디오 계층이 사용할 판단 기준만 제공한다.
  bool shouldSuppressRepeatedCue(
    BoneConductionAudioCue previous,
    BoneConductionAudioCue next, {
    Duration repeatCooldown = const Duration(seconds: 2),
  }) {
    if (next.urgency == BoneConductionCueUrgency.critical) {
      return false;
    }
    if (previous.beaconId != next.beaconId) {
      return false;
    }
    if (previous.sourceEventType == null ||
        previous.sourceEventType != next.sourceEventType) {
      return false;
    }

    final elapsed = next.createdAt.difference(previous.createdAt).abs();
    return elapsed < repeatCooldown;
  }

  /// 여러 cue가 같은 시점에 충돌할 때 가장 높은 우선순위 cue를 선택한다.
  ///
  /// 우선순위는 `critical > high > medium > low`이다. 같은 우선순위이면 최신 cue를 선택한다.
  BoneConductionAudioCue selectHighestPriorityCue(
    Iterable<BoneConductionAudioCue> cues,
  ) {
    if (cues.isEmpty) {
      throw ArgumentError('At least one cue is required to resolve priority.');
    }

    return cues.reduce((selected, candidate) {
      final selectedRank = _urgencyRank(selected.urgency);
      final candidateRank = _urgencyRank(candidate.urgency);
      if (candidateRank > selectedRank) {
        return candidate;
      }
      if (candidateRank == selectedRank &&
          candidate.createdAt.isAfter(selected.createdAt)) {
        return candidate;
      }
      return selected;
    });
  }

  /// [ProximityEvent] stream을 [BoneConductionAudioCue] stream으로 변환한다.
  ///
  /// Passenger App은 섹션 5의 proximity event stream을 그대로 이 factory에 넘겨
  /// eventType별 안내 문구, 긴급도, 반복 간격 payload를 얻을 수 있다.
  Stream<BoneConductionAudioCue> createCueStreamFromEvents(
    Stream<ProximityEvent> events, {
    bool suppressRepeatedEvents = false,
    Duration repeatCooldown = const Duration(seconds: 2),
  }) async* {
    BoneConductionAudioCue? previousCue;

    await for (final event in events) {
      final cue = createCueForEvent(event);
      if (suppressRepeatedEvents &&
          previousCue != null &&
          shouldSuppressRepeatedCue(
            previousCue,
            cue,
            repeatCooldown: repeatCooldown,
          )) {
        continue;
      }

      previousCue = cue;
      yield cue;
    }
  }

  int _urgencyRank(BoneConductionCueUrgency urgency) {
    switch (urgency) {
      case BoneConductionCueUrgency.low:
        return 1;
      case BoneConductionCueUrgency.medium:
        return 2;
      case BoneConductionCueUrgency.high:
        return 3;
      case BoneConductionCueUrgency.critical:
        return 4;
    }
  }

  /// 단일 [BeaconSignal]을 안내 cue로 변환한다.
  ///
  /// [proximitySnapshot]이 있으면 snapshot의 trend를 우선 사용하고,
  /// 없으면 [proximityTrend]를 사용한다.
  BoneConductionAudioCue createCue(
    BeaconSignal signal, {
    BeaconProximitySnapshot? proximitySnapshot,
    BeaconProximityTrend? proximityTrend,
    DateTime? createdAt,
  }) {
    final resolvedTrend = proximitySnapshot?.trend ?? proximityTrend;
    return BoneConductionAudioCue.fromBeaconSignal(
      signal,
      proximityTrend: resolvedTrend,
      createdAt: createdAt ?? proximitySnapshot?.updatedAt,
    );
  }

  /// 비콘 신호를 잃었을 때 사용할 lost cue를 생성한다.
  BoneConductionAudioCue createLostCue(
    String beaconId, {
    DateTime? createdAt,
  }) {
    final timestamp = createdAt ?? DateTime.now();
    final signal = BeaconSignal(
      beaconId: beaconId,
      rssi: defaultLostRssi,
      estimatedDistanceMeters: null,
      signalLevel: BeaconSignalLevel.lost,
      lastDetectedAt: timestamp,
    );
    return createCue(
      signal,
      proximityTrend: BeaconProximityTrend.unknown,
      createdAt: timestamp,
    );
  }

  /// [BeaconSignal] stream을 [BoneConductionAudioCue] stream으로 변환한다.
  ///
  /// [tracker]가 주어지면 최근 signal 변화량으로 가까워짐/멀어짐 추세를 함께
  /// 반영한다. 주어지지 않으면 기본 [BeaconProximityTracker]를 사용한다.
  Stream<BoneConductionAudioCue> createCueStream(
    Stream<BeaconSignal> signals, {
    BeaconProximityTracker? tracker,
  }) async* {
    final effectiveTracker = tracker ?? BeaconProximityTracker();

    await for (final signal in signals) {
      final snapshot = effectiveTracker.addSignal(signal);
      yield createCue(signal, proximitySnapshot: snapshot);
    }
  }
}
