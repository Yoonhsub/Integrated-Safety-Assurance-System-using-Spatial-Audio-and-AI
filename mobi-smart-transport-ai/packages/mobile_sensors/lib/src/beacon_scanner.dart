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
/// The default implementation prefers the advertised local name and falls back
/// to the device remote id. A real field deployment may replace this resolver
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
    BeaconIdResolver? beaconIdResolver,
  })  : assert(smoothingWindowSize > 0, 'smoothingWindowSize must be greater than 0'),
        beaconIdResolver = beaconIdResolver ?? defaultBeaconIdResolver;

  final BeaconDistanceEstimator estimator;
  final Duration scanTimeout;
  final int smoothingWindowSize;
  final BeaconIdResolver beaconIdResolver;

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
    _isScanning = true;
    _smoothers.clear();
    final deadline = DateTime.now().add(scanTimeout);

    try {
      await FlutterBluePlus.startScan(timeout: scanTimeout);

      await for (final results in FlutterBluePlus.scanResults) {
        if (!_isScanning || DateTime.now().isAfter(deadline)) {
          break;
        }

        for (final result in results) {
          if (!_isScanning) {
            break;
          }

          final beaconId = beaconIdResolver(result).trim();
          if (beaconId.isEmpty) {
            continue;
          }

          final smoother = _smoothers.putIfAbsent(
            beaconId,
            () => RssiMovingAverageSmoother(windowSize: smoothingWindowSize),
          );
          final smoothedRssi = smoother.addSample(result.rssi);

          final signal = estimator.buildSignal(
            beaconId: beaconId,
            rssi: smoothedRssi,
            lastDetectedAt: DateTime.now(),
          );

          if (BeaconScannerFilters.matchesTarget(signal, targetBeaconId)) {
            yield signal;
          }
        }
      }
    } finally {
      await stop();
    }
  }

  @override
  Future<void> stop() async {
    if (!_isScanning) {
      return;
    }
    _isScanning = false;
    _smoothers.clear();
    await FlutterBluePlus.stopScan();
  }

  /// 기본 beaconId 추출 규칙이다.
  ///
  /// 광고 이름이 있으면 사람이 읽기 쉬운 ID로 사용하고, 없으면 BLE remote id를
  /// 사용한다. 실제 정류장 비콘 모델이 확정되면 UUID/manufacturer data 기반
  /// resolver로 교체할 수 있다.
  static String defaultBeaconIdResolver(ScanResult result) {
    final advertisedName = result.advertisementData.advName;
    if (advertisedName.isNotEmpty) {
      return advertisedName;
    }
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
