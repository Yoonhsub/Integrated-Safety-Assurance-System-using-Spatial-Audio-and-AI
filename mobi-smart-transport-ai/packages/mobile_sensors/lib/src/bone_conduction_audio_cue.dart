import 'beacon_signal.dart';
import 'beacon_proximity_tracker.dart';

/// 골전도 이어폰 또는 앱 오디오 모듈이 소비할 수 있는 안내 긴급도이다.
///
/// 이 enum은 실제 TTS 재생, 블루투스 연결, 공간음향 렌더링을 수행하지 않는다.
/// BLE 비콘 거리 상태를 바탕으로 어떤 수준의 안내를 준비해야 하는지 표현한다.
enum BoneConductionCueUrgency { low, medium, high, critical }

extension BoneConductionCueUrgencyJson on BoneConductionCueUrgency {
  String toJsonValue() {
    switch (this) {
      case BoneConductionCueUrgency.low:
        return 'LOW';
      case BoneConductionCueUrgency.medium:
        return 'MEDIUM';
      case BoneConductionCueUrgency.high:
        return 'HIGH';
      case BoneConductionCueUrgency.critical:
        return 'CRITICAL';
    }
  }

  static BoneConductionCueUrgency fromJsonValue(String value) {
    switch (value) {
      case 'LOW':
        return BoneConductionCueUrgency.low;
      case 'MEDIUM':
        return BoneConductionCueUrgency.medium;
      case 'HIGH':
        return BoneConductionCueUrgency.high;
      case 'CRITICAL':
        return BoneConductionCueUrgency.critical;
      default:
        throw ArgumentError('Unknown BoneConductionCueUrgency JSON value: $value');
    }
  }
}

/// 비콘 거리 상태를 골전도 이어폰 안내로 바꾸기 위한 데이터 계약이다.
///
/// 이 모델은 직접 소리를 재생하지 않는다. Flutter 앱의 TTS, 알림음, 진동,
/// 또는 향후 오디오 모듈이 이 cue를 읽어 실제 출력을 담당한다.
class BoneConductionAudioCue {
  const BoneConductionAudioCue({
    required this.cueId,
    required this.beaconId,
    required this.message,
    required this.signalLevel,
    required this.urgency,
    required this.repeatIntervalMs,
    required this.createdAt,
    this.estimatedDistanceMeters,
    this.proximityTrend,
    this.shouldRepeat = true,
  })  : assert(cueId.length > 0, 'cueId must not be empty'),
        assert(beaconId.length > 0, 'beaconId must not be empty'),
        assert(message.length > 0, 'message must not be empty'),
        assert(repeatIntervalMs >= 0, 'repeatIntervalMs must be zero or greater');

  /// 앱 또는 로그에서 cue를 구분하기 위한 ID이다.
  final String cueId;

  /// 안내 대상 비콘 ID이다.
  final String beaconId;

  /// TTS 또는 화면 로그에서 사용할 짧은 안내 문장이다.
  final String message;

  /// cue 생성에 사용된 비콘 신호 단계이다.
  final BeaconSignalLevel signalLevel;

  /// RSSI 기반 추정 거리이다. 추정 불가하면 null을 유지한다.
  final double? estimatedDistanceMeters;

  /// 최근 비콘 접근 추세이다. 추세 판단을 수행하지 않았다면 null일 수 있다.
  final BeaconProximityTrend? proximityTrend;

  /// 안내 우선순위 또는 위험도 힌트이다.
  final BoneConductionCueUrgency urgency;

  /// 반복 안내 권장 간격이다. 실제 반복 타이머는 앱 또는 오디오 모듈이 담당한다.
  final int repeatIntervalMs;

  /// 이 cue가 반복 안내 대상인지 나타낸다.
  final bool shouldRepeat;

  /// cue 생성 시각이다.
  final DateTime createdAt;

  bool get isCritical => urgency == BoneConductionCueUrgency.critical;

  BoneConductionAudioCue copyWith({
    String? cueId,
    String? beaconId,
    String? message,
    BeaconSignalLevel? signalLevel,
    double? estimatedDistanceMeters,
    bool clearEstimatedDistanceMeters = false,
    BeaconProximityTrend? proximityTrend,
    bool clearProximityTrend = false,
    BoneConductionCueUrgency? urgency,
    int? repeatIntervalMs,
    bool? shouldRepeat,
    DateTime? createdAt,
  }) {
    return BoneConductionAudioCue(
      cueId: cueId ?? this.cueId,
      beaconId: beaconId ?? this.beaconId,
      message: message ?? this.message,
      signalLevel: signalLevel ?? this.signalLevel,
      estimatedDistanceMeters: clearEstimatedDistanceMeters
          ? null
          : estimatedDistanceMeters ?? this.estimatedDistanceMeters,
      proximityTrend: clearProximityTrend
          ? null
          : proximityTrend ?? this.proximityTrend,
      urgency: urgency ?? this.urgency,
      repeatIntervalMs: repeatIntervalMs ?? this.repeatIntervalMs,
      shouldRepeat: shouldRepeat ?? this.shouldRepeat,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toJson() => {
        'cueId': cueId,
        'beaconId': beaconId,
        'message': message,
        'signalLevel': signalLevel.toJsonValue(),
        'estimatedDistanceMeters': estimatedDistanceMeters,
        'proximityTrend': proximityTrend?.toJsonValue(),
        'urgency': urgency.toJsonValue(),
        'repeatIntervalMs': repeatIntervalMs,
        'shouldRepeat': shouldRepeat,
        'createdAt': createdAt.toIso8601String(),
      };

  factory BoneConductionAudioCue.fromJson(Map<String, Object?> json) {
    final cueId = json['cueId'];
    final beaconId = json['beaconId'];
    final message = json['message'];
    final signalLevel = json['signalLevel'];
    final estimatedDistanceMeters = json['estimatedDistanceMeters'];
    final proximityTrend = json['proximityTrend'];
    final urgency = json['urgency'];
    final repeatIntervalMs = json['repeatIntervalMs'];
    final shouldRepeat = json['shouldRepeat'];
    final createdAt = json['createdAt'];

    if (cueId is! String || cueId.isEmpty) {
      throw ArgumentError('BoneConductionAudioCue.cueId must be a non-empty string.');
    }
    if (beaconId is! String || beaconId.isEmpty) {
      throw ArgumentError('BoneConductionAudioCue.beaconId must be a non-empty string.');
    }
    if (message is! String || message.isEmpty) {
      throw ArgumentError('BoneConductionAudioCue.message must be a non-empty string.');
    }
    if (signalLevel is! String) {
      throw ArgumentError('BoneConductionAudioCue.signalLevel must be a string.');
    }
    if (estimatedDistanceMeters != null && estimatedDistanceMeters is! num) {
      throw ArgumentError(
        'BoneConductionAudioCue.estimatedDistanceMeters must be a number or null.',
      );
    }
    if (proximityTrend != null && proximityTrend is! String) {
      throw ArgumentError('BoneConductionAudioCue.proximityTrend must be a string or null.');
    }
    if (urgency is! String) {
      throw ArgumentError('BoneConductionAudioCue.urgency must be a string.');
    }
    if (repeatIntervalMs is! num) {
      throw ArgumentError('BoneConductionAudioCue.repeatIntervalMs must be a number.');
    }
    if (shouldRepeat is! bool) {
      throw ArgumentError('BoneConductionAudioCue.shouldRepeat must be a boolean.');
    }
    if (createdAt is! String) {
      throw ArgumentError('BoneConductionAudioCue.createdAt must be an ISO-8601 string.');
    }

    return BoneConductionAudioCue(
      cueId: cueId,
      beaconId: beaconId,
      message: message,
      signalLevel: BeaconSignalLevelJson.fromJsonValue(signalLevel),
      estimatedDistanceMeters: estimatedDistanceMeters == null
          ? null
          : (estimatedDistanceMeters as num).toDouble(),
      proximityTrend: proximityTrend == null
          ? null
          : _proximityTrendFromJsonValue(proximityTrend),
      urgency: BoneConductionCueUrgencyJson.fromJsonValue(urgency),
      repeatIntervalMs: repeatIntervalMs.toInt(),
      shouldRepeat: shouldRepeat,
      createdAt: DateTime.parse(createdAt),
    );
  }

  static BeaconProximityTrend _proximityTrendFromJsonValue(String value) {
    switch (value) {
      case 'APPROACHING':
        return BeaconProximityTrend.approaching;
      case 'MOVING_AWAY':
        return BeaconProximityTrend.movingAway;
      case 'STABLE':
        return BeaconProximityTrend.stable;
      case 'UNKNOWN':
        return BeaconProximityTrend.unknown;
      default:
        throw ArgumentError('Unknown BeaconProximityTrend JSON value: $value');
    }
  }

  /// 비콘 신호 단계에 맞춘 기본 안내 cue를 생성한다.
  ///
  /// 실제 문구 교체, 다국어 처리, TTS 음성 선택은 Flutter 앱 또는 오디오 담당
  /// 모듈에서 확장할 수 있다.
  factory BoneConductionAudioCue.fromBeaconSignal(
    BeaconSignal signal, {
    BeaconProximityTrend? proximityTrend,
    DateTime? createdAt,
  }) {
    final now = createdAt ?? DateTime.now();
    return BoneConductionAudioCue(
      cueId: 'beacon-${signal.beaconId}-${now.millisecondsSinceEpoch}',
      beaconId: signal.beaconId,
      message: _messageForLevel(signal.signalLevel, proximityTrend),
      signalLevel: signal.signalLevel,
      estimatedDistanceMeters: signal.estimatedDistanceMeters,
      proximityTrend: proximityTrend,
      urgency: _urgencyForLevel(signal.signalLevel),
      repeatIntervalMs: _repeatIntervalForLevel(signal.signalLevel),
      shouldRepeat: signal.signalLevel != BeaconSignalLevel.veryClose,
      createdAt: now,
    );
  }

  static String _messageForLevel(
    BeaconSignalLevel level,
    BeaconProximityTrend? trend,
  ) {
    if (trend == BeaconProximityTrend.movingAway) {
      return '목표 위치에서 멀어지고 있습니다. 방향을 다시 확인하세요.';
    }

    switch (level) {
      case BeaconSignalLevel.veryClose:
        return '탑승 위치에 거의 도착했습니다.';
      case BeaconSignalLevel.close:
        return '버스 문이 가까이에 있습니다.';
      case BeaconSignalLevel.medium:
        return '조금 더 앞으로 이동하세요.';
      case BeaconSignalLevel.far:
        return '목표 위치와 아직 떨어져 있습니다.';
      case BeaconSignalLevel.lost:
        return '비콘 신호가 약합니다. 주변을 다시 확인하세요.';
    }
  }

  static BoneConductionCueUrgency _urgencyForLevel(BeaconSignalLevel level) {
    switch (level) {
      case BeaconSignalLevel.veryClose:
        return BoneConductionCueUrgency.low;
      case BeaconSignalLevel.close:
        return BoneConductionCueUrgency.medium;
      case BeaconSignalLevel.medium:
        return BoneConductionCueUrgency.medium;
      case BeaconSignalLevel.far:
        return BoneConductionCueUrgency.high;
      case BeaconSignalLevel.lost:
        return BoneConductionCueUrgency.critical;
    }
  }

  static int _repeatIntervalForLevel(BeaconSignalLevel level) {
    switch (level) {
      case BeaconSignalLevel.veryClose:
        return 0;
      case BeaconSignalLevel.close:
        return 3000;
      case BeaconSignalLevel.medium:
        return 2000;
      case BeaconSignalLevel.far:
        return 1500;
      case BeaconSignalLevel.lost:
        return 1000;
    }
  }
}
