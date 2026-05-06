import 'beacon_signal.dart';

abstract class BeaconScanner {
  Stream<BeaconSignal> scan({String? targetBeaconId});
  Future<void> stop();
}

class UnimplementedBeaconScanner implements BeaconScanner {
  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) {
    // TODO(안준환): flutter_blue_plus 기반 BLE 스캔 구현.
    return const Stream.empty();
  }

  @override
  Future<void> stop() async {}
}
