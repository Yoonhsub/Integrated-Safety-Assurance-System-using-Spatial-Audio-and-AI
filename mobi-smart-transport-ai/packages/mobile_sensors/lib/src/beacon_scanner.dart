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

class UnimplementedBeaconScanner implements BeaconScanner {
  bool _isScanning = false;

  @override
  bool get isScanning => _isScanning;

  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) async* {
    // TODO(안준환): flutter_blue_plus 기반 BLE 스캔 구현.
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
