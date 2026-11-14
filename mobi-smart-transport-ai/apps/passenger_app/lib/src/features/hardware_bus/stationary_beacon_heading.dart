import 'beacon_tone_interval.dart';
import 'wit_sensor_protocol.dart';

/// Explicit stationary demonstration only. No bearing from RSSI, translation,
/// meters or authenticated vehicle identity is inferred.
class StationaryBeaconHeading {
  double? bearing;
  double? _reference;
  String? _scope;
  bool? _reverse;
  double? _rssi;
  DateTime? _sample;
  int intervalMs = 1000;
  bool get calibrated => bearing != null;
  String get proximity => 'UNKNOWN';

  void invalidate() {
    bearing = _reference = _rssi = null;
    _scope = null;
    _reverse = null;
    _sample = null;
    intervalMs = 1000;
  }

  bool matches(String scope, double reference, bool reverse) =>
      calibrated &&
      _scope == scope &&
      _reference == reference &&
      _reverse == reverse;

  void calibrate(
      {required double yaw,
      required double reference,
      required String scope,
      required bool reverse}) {
    if (!yaw.isFinite || !reference.isFinite || scope.isEmpty) {
      throw ArgumentError(
          'Finite heading and explicit target/session scope required');
    }
    invalidate();
    _reference = reference;
    _scope = scope;
    _reverse = reverse;
    bearing = relativeAngle(yaw, reference) * (reverse ? -1 : 1);
  }

  /// A fresh packet after a lost-radio interval cannot restore old calibration,
  /// even if the UI timer was suspended and never observed the stale period.
  bool hasSampleGap(DateTime sampledAt) =>
      _sample != null &&
      sampledAt.difference(_sample!) >= const Duration(seconds: 3);

  /// Once per actual radio sample, not per UI heartbeat. EMA + 60 ms deadband.
  void addRssi(int rssi, DateTime sampledAt) {
    if (rssi < -127 ||
        rssi >= 0 ||
        (_sample != null && !sampledAt.isAfter(_sample!))) {
      return;
    }
    _sample = sampledAt;
    _rssi = _rssi == null ? rssi.toDouble() : _rssi! + .25 * (rssi - _rssi!);
    final next = beaconToneIntervalMs(_rssi!.round());
    if ((next - intervalMs).abs() >= 60) intervalMs = next;
  }
}
