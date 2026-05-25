import 'dart:async';

import 'beacon_audio_cue_factory.dart';
import 'beacon_proximity_tracker.dart';
import 'beacon_scanner.dart';
import 'bone_conduction_audio_cue.dart';
import 'proximity_event_stream.dart';

/// Passenger App이 sensor adapter 연결 전에 확인할 권한/기기 상태이다.
///
/// 이 enum은 실제 권한 요청 UI를 만들지 않는다. Android/iOS 권한 요청과 안내
/// 화면은 `apps/passenger_app/**` 담당이며, 이 패키지는 앱이 상태를 전달하거나
/// 로깅할 수 있는 공통 값만 제공한다.
enum PassengerSensorPermissionStatus {
  unknown,
  ready,
  bluetoothPermissionDenied,
  locationPermissionDenied,
  bluetoothOff,
  locationOff,
  unavailable,
}

extension PassengerSensorPermissionStatusJson
    on PassengerSensorPermissionStatus {
  String toJsonValue() {
    switch (this) {
      case PassengerSensorPermissionStatus.unknown:
        return 'UNKNOWN';
      case PassengerSensorPermissionStatus.ready:
        return 'READY';
      case PassengerSensorPermissionStatus.bluetoothPermissionDenied:
        return 'BLUETOOTH_PERMISSION_DENIED';
      case PassengerSensorPermissionStatus.locationPermissionDenied:
        return 'LOCATION_PERMISSION_DENIED';
      case PassengerSensorPermissionStatus.bluetoothOff:
        return 'BLUETOOTH_OFF';
      case PassengerSensorPermissionStatus.locationOff:
        return 'LOCATION_OFF';
      case PassengerSensorPermissionStatus.unavailable:
        return 'UNAVAILABLE';
    }
  }
}

/// Passenger App이 센서 구독 전후로 기록할 수 있는 권한/기기 상태 snapshot이다.
class PassengerSensorPermissionSnapshot {
  const PassengerSensorPermissionSnapshot({
    required this.status,
    required this.checkedAt,
    this.bluetoothPermissionGranted,
    this.locationPermissionGranted,
    this.bluetoothEnabled,
    this.locationServiceEnabled,
    this.message,
  });

  factory PassengerSensorPermissionSnapshot.ready({DateTime? checkedAt}) {
    return PassengerSensorPermissionSnapshot(
      status: PassengerSensorPermissionStatus.ready,
      checkedAt: checkedAt ?? DateTime.now(),
      bluetoothPermissionGranted: true,
      locationPermissionGranted: true,
      bluetoothEnabled: true,
      locationServiceEnabled: true,
      message: 'Sensor permissions and device services are ready.',
    );
  }

  factory PassengerSensorPermissionSnapshot.unknown({
    DateTime? checkedAt,
    String? message,
  }) {
    return PassengerSensorPermissionSnapshot(
      status: PassengerSensorPermissionStatus.unknown,
      checkedAt: checkedAt ?? DateTime.now(),
      message: message ??
          'Permission state is not checked inside mobile_sensors. Passenger App should check platform permissions before starting scan.',
    );
  }

  final PassengerSensorPermissionStatus status;
  final bool? bluetoothPermissionGranted;
  final bool? locationPermissionGranted;
  final bool? bluetoothEnabled;
  final bool? locationServiceEnabled;
  final DateTime checkedAt;
  final String? message;

  /// 실제 스캔을 시작해도 되는 상태인지에 대한 앱 판단용 helper이다.
  bool get canStartScan => status == PassengerSensorPermissionStatus.ready;

  Map<String, Object?> toJson() => {
        'status': status.toJsonValue(),
        'bluetoothPermissionGranted': bluetoothPermissionGranted,
        'locationPermissionGranted': locationPermissionGranted,
        'bluetoothEnabled': bluetoothEnabled,
        'locationServiceEnabled': locationServiceEnabled,
        'checkedAt': checkedAt.toIso8601String(),
        'message': message,
      };
}

/// 권한 상태를 앱 계층에서 주입하기 위한 callback이다.
///
/// 이 패키지는 권한 요청 UI를 직접 만들지 않으므로, Passenger App은
/// permission_handler 또는 플랫폼 API 결과를 이 callback 결과로 변환해 넘긴다.
typedef PassengerSensorPermissionProvider =
    Future<PassengerSensorPermissionSnapshot> Function();

/// Passenger App에서 sensor stream을 연결할 때 사용할 기본 설정이다.
class PassengerSensorAdapterConfig {
  const PassengerSensorAdapterConfig({
    this.targetBeaconId,
    this.suppressRepeatedAudioCues = true,
    this.audioCueRepeatCooldown = const Duration(seconds: 2),
  });

  /// 특정 정류장/탑승 위치 비콘만 구독하고 싶을 때 사용한다.
  final String? targetBeaconId;

  /// 같은 event가 짧게 반복될 때 cue stream에서 중복 안내를 억제할지 여부이다.
  final bool suppressRepeatedAudioCues;

  /// 반복 cue 억제 기준 시간이다.
  final Duration audioCueRepeatCooldown;
}

/// Passenger App이 의존할 수 있는 센서 서비스 interface이다.
///
/// 앱은 이 interface를 기준으로 stream subscription, stop, dispose lifecycle을
/// 연결할 수 있다. 실제 앱 화면, 권한 요청 UI, TTS 실행은 이 패키지 범위가 아니다.
abstract class PassengerSensorService {
  bool get isDisposed;

  Future<PassengerSensorPermissionSnapshot> checkPermissionStatus();

  Stream<ProximityEvent> watchProximityEvents({
    String? targetBeaconId,
    ProximityDirectionProvider? directionProvider,
  });

  Stream<BoneConductionAudioCue> watchAudioCues({
    String? targetBeaconId,
    ProximityDirectionProvider? directionProvider,
    bool? suppressRepeatedAudioCues,
    Duration? repeatCooldown,
  });

  Future<void> stop();

  Future<void> dispose();
}

/// `BeaconScanner`를 Passenger App용 proximity/audio cue stream으로 묶는 adapter이다.
///
/// 이 클래스는 앱 코드를 수정하지 않고, 앱이 가져다 쓸 sensor service 기준만
/// 제공한다. 권한 요청과 플랫폼별 안내는 Passenger App에서 수행한다.
class MobileSensorPassengerAdapter implements PassengerSensorService {
  MobileSensorPassengerAdapter({
    required BeaconScanner scanner,
    BeaconProximityTracker? tracker,
    BeaconAudioCueFactory? cueFactory,
    PassengerSensorAdapterConfig config = const PassengerSensorAdapterConfig(),
    PassengerSensorPermissionProvider? permissionProvider,
  })  : _scanner = scanner,
        _tracker = tracker ?? BeaconProximityTracker(),
        _cueFactory = cueFactory ?? const BeaconAudioCueFactory(),
        _config = config,
        _permissionProvider = permissionProvider;

  final BeaconScanner _scanner;
  final BeaconProximityTracker _tracker;
  final BeaconAudioCueFactory _cueFactory;
  final PassengerSensorAdapterConfig _config;
  final PassengerSensorPermissionProvider? _permissionProvider;

  bool _isDisposed = false;

  @override
  bool get isDisposed => _isDisposed;

  /// 앱 계층에서 주입한 권한 provider를 호출한다.
  ///
  /// provider가 없으면 `UNKNOWN`을 반환한다. 이 경우 패키지가 권한을 확인하지
  /// 못했다는 뜻이며, 앱은 자체 권한 확인 후 stream을 구독해야 한다.
  @override
  Future<PassengerSensorPermissionSnapshot> checkPermissionStatus() async {
    _ensureNotDisposed();
    final provider = _permissionProvider;
    if (provider == null) {
      return PassengerSensorPermissionSnapshot.unknown();
    }
    return provider();
  }

  /// Passenger App이 구독할 proximity event stream이다.
  ///
  /// 반환된 stream은 앱에서 `StreamSubscription`으로 보관하고 화면 종료 시
  /// `cancel()`한 뒤 [dispose]를 호출하는 방식으로 사용한다.
  @override
  Stream<ProximityEvent> watchProximityEvents({
    String? targetBeaconId,
    ProximityDirectionProvider? directionProvider,
  }) async* {
    _ensureNotDisposed();
    final adapter = ProximityEventStreamAdapter(
      scanner: _scanner,
      tracker: _tracker,
    );
    yield* adapter.watch(
      targetBeaconId: targetBeaconId ?? _config.targetBeaconId,
      directionProvider: directionProvider,
    );
  }

  /// proximity event stream을 audio cue stream으로 변환한다.
  ///
  /// 실제 TTS 호출이나 골전도 이어폰 제어는 수행하지 않고, 앱이 소비할 cue
  /// payload만 생성한다.
  @override
  Stream<BoneConductionAudioCue> watchAudioCues({
    String? targetBeaconId,
    ProximityDirectionProvider? directionProvider,
    bool? suppressRepeatedAudioCues,
    Duration? repeatCooldown,
  }) {
    _ensureNotDisposed();
    final events = watchProximityEvents(
      targetBeaconId: targetBeaconId,
      directionProvider: directionProvider,
    );
    return _cueFactory.createCueStreamFromEvents(
      events,
      suppressRepeatedEvents:
          suppressRepeatedAudioCues ?? _config.suppressRepeatedAudioCues,
      repeatCooldown: repeatCooldown ?? _config.audioCueRepeatCooldown,
    );
  }

  /// 진행 중인 scan을 중지한다. 화면 pause, route 이탈, 권한 해제 시 호출한다.
  @override
  Future<void> stop() async {
    await _scanner.stop();
    _tracker.reset();
  }

  /// 앱 화면이 완전히 종료될 때 호출하는 정리 hook이다.
  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await stop();
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('MobileSensorPassengerAdapter is already disposed.');
    }
  }
}
