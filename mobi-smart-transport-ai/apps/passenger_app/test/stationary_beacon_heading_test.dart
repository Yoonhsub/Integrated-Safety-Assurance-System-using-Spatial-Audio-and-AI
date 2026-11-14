import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/stationary_beacon_heading.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/direction_pan.dart';

void main() {
  test('same reference target gaze, right turn moves target left', () {
    final c = StationaryBeaconHeading();
    c.calibrate(
        yaw: 65, reference: 20, scope: 'MAC-A/session1', reverse: false);
    expect(c.bearing, 45);
    expect(DirectionPan.fromZ(65, 20, objectAngle: c.bearing!).targetAngle, 0);
    expect(
        DirectionPan.fromZ(110, 20, objectAngle: c.bearing!).targetAngle, -45);
    expect(c.proximity, 'UNKNOWN');
    expect(c.matches('MAC-B/session1', 20, false), isFalse);
    expect(c.matches('MAC-A/session2', 20, false), isFalse);
    expect(c.matches('MAC-A/session1', 21, false), isFalse);
    expect(c.matches('MAC-A/session1', 20, true), isFalse);
  });
  test('wrap and reversed sensor sign', () {
    final c = StationaryBeaconHeading();
    c.calibrate(yaw: 179, reference: 150, scope: 'a', reverse: false);
    expect(
        DirectionPan.fromZ(-179, 150, objectAngle: c.bearing!).targetAngle, -2);
    c.calibrate(yaw: 65, reference: 20, scope: 'a', reverse: true);
    expect(
        DirectionPan.fromZ(20, 20, reverse: true, objectAngle: c.bearing!)
            .targetAngle,
        -45);
  });
  test(
      'RSSI once per new sample, smoother stronger pacing, bounded, no auto calibration',
      () {
    final c = StationaryBeaconHeading();
    final t = DateTime.utc(2026);
    c.addRssi(-85, t);
    expect(c.intervalMs, 1400);
    c.addRssi(-45, t);
    expect(c.intervalMs, 1400);
    c.addRssi(-45, t.subtract(const Duration(seconds: 1)));
    expect(c.intervalMs, 1400);
    c.addRssi(-45, t.add(const Duration(seconds: 1)));
    expect(c.intervalMs, inExclusiveRange(220, 1400));
    for (var i = 2; i < 100; i++) {
      c.addRssi(-30, t.add(Duration(seconds: i)));
    }
    expect(c.intervalMs, inInclusiveRange(220, 280));
    final last = c.intervalMs;
    c.addRssi(0, t.add(const Duration(seconds: 101)));
    expect(c.intervalMs, last);
    c.invalidate();
    c.addRssi(-60, t.add(const Duration(seconds: 102)));
    expect(c.calibrated, isFalse);
  });
  test('sample gap detects loss despite no intermediate timer heartbeat', () {
    final c = StationaryBeaconHeading();
    final t = DateTime.utc(2026);
    c.calibrate(yaw: 0, reference: 0, scope: 'a', reverse: false);
    c.addRssi(-60, t);
    expect(c.hasSampleGap(t.add(const Duration(milliseconds: 2999))), isFalse);
    expect(c.hasSampleGap(t.add(const Duration(seconds: 3))), isTrue);
  });
}
