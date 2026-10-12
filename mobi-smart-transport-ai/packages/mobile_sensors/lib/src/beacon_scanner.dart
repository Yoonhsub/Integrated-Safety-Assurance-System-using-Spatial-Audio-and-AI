import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'beacon_distance_estimator.dart';
import 'beacon_signal.dart';

abstract class BeaconScanner {
  bool get isScanning;

  Stream<BeaconSignal> scan({String? targetBeaconId});
  Future<void> stop();
}

class BeaconScannerFilters {
  const BeaconScannerFilters._();

  static bool matchesTarget(BeaconSignal signal, String? targetBeaconId) {
    if (targetBeaconId == null || targetBeaconId.isEmpty) {
      return true;
    }
    return signal.beaconId == targetBeaconId;
  }
}

/// Resolves a stable MOBI beacon identifier from a BLE scan result.
///
/// The default uses the device remote id; shared advertising names are not unique. A real field deployment may replace this resolver
/// with a rule based on UUID/manufacturer data after the beacon model is fixed.
typedef BeaconIdResolver = String Function(ScanResult result);

/// flutter_blue_plus 기반 BLE scanner 구현체이다.
///
/// 이 클래스는 앱 화면, 권한 안내 UI, Android/iOS manifest 설정을 직접 다루지
/// 않는다. 앱 계층에서 BLE 권한과 Bluetooth 상태를 준비한 뒤, 이 패키지는
/// 스캔 결과를 [BeaconSignal] 모델로 변환하는 책임만 가진다.
class FlutterBlueBeaconScanner implements BeaconScanner {
  FlutterBlueBeaconScanner({
    this.estimator = const BeaconDistanceEstimator(),
    this.scanTimeout = const Duration(seconds: 10),
    this.smoothingWindowSize = 5,
    this.maxSingleSampleDelta = 10,
    this.lostResetThreshold = 3,
    BeaconIdResolver? beaconIdResolver,
    this.maxObservationAge = const Duration(seconds: 5),
    Stream<List<ScanResult>>? scanResults,
    Future<void> Function()? startScan,
    Future<void> Function()? stopScan,
    DateTime Function()? now,
  })  : assert(smoothingWindowSize > 0,
            'smoothingWindowSize must be greater than 0'),
        assert(
          maxSingleSampleDelta > 0,
          'maxSingleSampleDelta must be greater than 0',
        ),
        assert(
          lostResetThreshold > 0,
          'lostResetThreshold must be greater than 0',
        ),
        beaconIdResolver = beaconIdResolver ?? defaultBeaconIdResolver,
        _scanResults = scanResults,
        _startScan = startScan,
        _stopScan = stopScan,
        _now = now ?? DateTime.now;

  final BeaconDistanceEstimator estimator;
  final Duration scanTimeout;
  final int smoothingWindowSize;
  final int maxSingleSampleDelta;
  final int lostResetThreshold;
  final BeaconIdResolver beaconIdResolver;
  final Duration maxObservationAge;
  final Stream<List<ScanResult>>? _scanResults;
  final Future<void> Function()? _startScan;
  final Future<void> Function()? _stopScan;
  final DateTime Function() _now;
  final Map<String, DateTime> _lastObservation = {};
  StreamController<BeaconSignal>? _output;
  StreamSubscription<List<ScanResult>>? _subscription;
  Timer? _timer;
  Future<void>? _stopping;
  Future<void>? _starting;
  bool _scanActive = false;

  final Map<String, RssiMovingAverageSmoother> _smoothers = {};
  bool _isScanning = false;

  @override
  bool get isScanning => _isScanning;

  /// 스캔 결과를 [BeaconSignal] stream으로 변환한다.
  ///
  /// [targetBeaconId]가 주어지면 해당 ID와 일치하는 비콘만 통과시킨다. RSSI는
  /// 비콘별 moving average smoother를 거친 뒤 거리 추정과 signal level 분류에
  /// 사용된다.
  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) async* {
    if (_scanActive) throw StateError('A BLE scan is already active.');
    _scanActive = true;
    _stopping = null;
    _starting = null;
    _isScanning = true;
    _smoothers.clear();
    // Keep callback watermarks across scan restarts to reject cached replays.
    final startedAt = _now();
    final output = StreamController<BeaconSignal>();
    _output = output;
    try {
      _subscription = (_scanResults ?? FlutterBluePlus.onScanResults).listen(
        (results) {
          if (!_isScanning) return;
          for (final result in results) {
            // Plugin callback time, NOT this list's emission/read/send time.
            final stamp = result.timeStamp;
            final age = _now().difference(stamp);
            final deviceKey = result.device.remoteId.str;
            final previous = _lastObservation[deviceKey];
            if (stamp.isBefore(startedAt) ||
                age.isNegative ||
                age >= maxObservationAge ||
                (previous != null && !stamp.isAfter(previous))) continue;
            _lastObservation[deviceKey] = stamp;
            final beaconId = beaconIdResolver(result).trim();
            if (beaconId.isEmpty) continue;
            if (previous != null &&
                stamp.difference(previous) >= maxObservationAge) {
              _smoothers.remove(deviceKey);
            }
            final smoother = _smoothers.putIfAbsent(
                deviceKey,
                () => RssiMovingAverageSmoother(
                      windowSize: smoothingWindowSize,
                      maxSingleSampleDelta: maxSingleSampleDelta,
                      lostResetThreshold: lostResetThreshold,
                    ));
            final signal = estimator.buildSignal(
              beaconId: beaconId,
              rssi: smoother.addSample(result.rssi),
              lastDetectedAt: stamp.toUtc(),
            );
            if (BeaconScannerFilters.matchesTarget(signal, targetBeaconId)) {
              output.add(signal);
            }
          }
        },
        onError: (Object error, StackTrace stack) {
          output.addError(error, stack);
          unawaited(stop().catchError((Object _) {}));
        },
        onDone: () => unawaited(stop().catchError((Object _) {})),
      );
      // End even when no advertisements arrive. stop() also wakes this stream.
      _timer =
          Timer(scanTimeout, () => unawaited(stop().catchError((Object _) {})));
      _starting = _startScan?.call() ??
          FlutterBluePlus.startScan(
            timeout: scanTimeout,
            continuousUpdates: true,
            continuousDivisor: 1,
          );
      await _starting;
      yield* output.stream;
    } finally {
      try {
        await stop();
      } finally {
        _scanActive = false;
      }
    }
  }

  @override
  Future<void> stop() => _stopping ??= _finishScan();

  Future<void> _finishScan() async {
    if (!_isScanning) return;
    _isScanning = false;
    _timer?.cancel();
    final subscription = _subscription;
    _subscription = null;
    final output = _output;
    _output = null;
    // Do not await close: the async generator must be allowed to consume done.
    if (output != null) unawaited(output.close());
    await subscription?.cancel();
    _smoothers.clear();
    try {
      await _starting;
    } catch (_) {
      // scan() propagates start errors; still release platform resources.
    }
    await (_stopScan?.call() ?? FlutterBluePlus.stopScan());
  }

  /// 기본 beaconId 추출 규칙이다.
  ///
  /// 공유 광고 이름 대신 BLE remote id를 사용한다. 차량 신원 증명은 아니다. 실제 정류장 비콘 모델이 확정되면 UUID/manufacturer data 기반
  /// resolver로 교체할 수 있다.
  static String defaultBeaconIdResolver(ScanResult result) {
    return result.device.remoteId.str;
  }
}

class UnimplementedBeaconScanner implements BeaconScanner {
  bool _isScanning = false;

  @override
  bool get isScanning => _isScanning;

  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) async* {
    // TODO(안준환): flutter_blue_plus 기반 실기기 스캔 전 앱 권한/기기 상태 연동 확인.
    // 이 skeleton은 앱 UI가 아니라 패키지 내부 scanner lifecycle 계약만 표현한다.
    _isScanning = true;
    try {
      yield* const Stream<BeaconSignal>.empty();
    } finally {
      _isScanning = false;
    }
  }

  @override
  Future<void> stop() async {
    _isScanning = false;
  }
}

class MockBeaconScanner implements BeaconScanner {
  MockBeaconScanner(this.signals);

  final Iterable<BeaconSignal> signals;
  bool _isScanning = false;

  @override
  bool get isScanning => _isScanning;

  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) async* {
    _isScanning = true;
    try {
      for (final signal in signals) {
        if (!_isScanning) {
          break;
        }
        if (BeaconScannerFilters.matchesTarget(signal, targetBeaconId)) {
          yield signal;
        }
      }
    } finally {
      _isScanning = false;
    }
  }

  @override
  Future<void> stop() async {
    _isScanning = false;
  }
}
