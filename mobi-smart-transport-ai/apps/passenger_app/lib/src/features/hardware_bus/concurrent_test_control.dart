import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

/// Local user-entered demonstration pairing, not a vehicle registry.
class TemporaryBusTarget {
  TemporaryBusTarget._(this.routeNo, this.mac);
  final String routeNo, mac;
  static TemporaryBusTarget? parse(String route, String address) {
    final number = route.trim();
    final mac = BeaconIngestPayload.maybeNormalizeMacAddress(address.trim());
    if (!RegExp(r'^[0-9A-Za-z가-힣-]{1,16}$').hasMatch(number) || mac == null) {
      return null;
    }
    return TemporaryBusTarget._(number, mac);
  }

  bool matches(BeaconSignal signal, DateTime now) {
    final age = now.difference(signal.lastDetectedAt);
    return BeaconIngestPayload.maybeNormalizeMacAddress(signal.beaconId) ==
            mac &&
        signal.rssi >= -120 &&
        signal.rssi < 0 &&
        !age.isNegative &&
        age < const Duration(seconds: 3);
  }

  String get announcement =>
      '시연 알림입니다. $routeNo번 버스가 진입 중입니다. 등록한 비콘 수신이며 실제 버스 접근을 확인한 것은 아닙니다.';
}

/// Only informational outputs share this non-preemptive slot. No sensor stops,
/// no queue of stale detections, no change to the safety priority coordinator.
class ConcurrentObservationGate {
  bool busy = false;
  Future<bool> run(Future<bool> Function() play) async {
    if (busy) return false;
    busy = true;
    try {
      return await play();
    } finally {
      busy = false;
    }
  }
}
