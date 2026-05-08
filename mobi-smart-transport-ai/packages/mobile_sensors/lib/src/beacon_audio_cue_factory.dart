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
