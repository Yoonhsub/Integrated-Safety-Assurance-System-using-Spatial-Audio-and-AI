import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/wit_sensor_protocol.dart';
import 'package:mobi_passenger_app/src/services/head_tracking_direction.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);

  HeadTrackingSnapshot ready(double yaw, {double reference = 0}) =>
      HeadTrackingSnapshot(
        status: HeadTrackingStatus.ready,
        rawYaw: yaw,
        filteredYaw: yaw,
        referenceYaw: reference,
        receivedAt: now.subtract(const Duration(milliseconds: 20)),
      );

  test('normalized bbox maps left center right with verified FOV', () {
    expect(
      horizontalAngleForNormalizedBbox(
        x: 0,
        width: .2,
        horizontalFovDegrees: 90,
      ),
      closeTo(-36, 1e-9),
    );
    expect(
      horizontalAngleForNormalizedBbox(
        x: .4,
        width: .2,
        horizontalFovDegrees: 90,
      ),
      closeTo(0, 1e-9),
    );
    expect(
      horizontalAngleForNormalizedBbox(
        x: .8,
        width: .2,
        horizontalFovDegrees: 90,
      ),
      closeTo(36, 1e-9),
    );
  });

  test('invalid bbox or unknown FOV is rejected', () {
    expect(
      () => horizontalAngleForNormalizedBbox(
        x: .9,
        width: .2,
        horizontalFovDegrees: 90,
      ),
      throwsArgumentError,
    );
    expect(
      () => horizontalAngleForNormalizedBbox(
        x: .4,
        width: .2,
        horizontalFovDegrees: 0,
      ),
      throwsArgumentError,
    );
  });

  test('right head rotation moves fixed front object left', () {
    expect(
      headTrackedAngleForMount(
        cameraAngle: 0,
        sensor: ready(30),
        now: now,
        calibration: fixed(),
      ),
      closeTo(-30, 1e-9),
    );
    expect(
      headTrackedAngleForMount(
        cameraAngle: 0,
        sensor: ready(-30),
        now: now,
        calibration: fixed(),
      ),
      closeTo(30, 1e-9),
    );
  });

  test('relative correction wraps at plus minus 180', () {
    expect(
      headTrackedAngleForMount(
        cameraAngle: -170,
        sensor: ready(170),
        now: now,
        calibration: fixed(),
      ),
      closeTo(20, 1e-9),
    );
    expect(
      headTrackedAngleForMount(
        cameraAngle: 170,
        sensor: ready(-170),
        now: now,
        calibration: fixed(),
      ),
      closeTo(-20, 1e-9),
    );
  });

  test('stale disconnected and uncalibrated samples fail closed', () {
    expect(
      headTrackedAngleForMount(
        cameraAngle: 0,
        sensor: HeadTrackingSnapshot(
          status: HeadTrackingStatus.ready,
          filteredYaw: 0,
          referenceYaw: 0,
          receivedAt: now.subtract(const Duration(seconds: 2)),
        ),
        now: now,
        calibration: fixed(),
      ),
      isNull,
    );
    expect(
      headTrackedAngleForMount(
        cameraAngle: 0,
        sensor: const HeadTrackingSnapshot(
          status: HeadTrackingStatus.connectedUncalibrated,
          filteredYaw: 0,
        ),
        now: now,
        calibration: fixed(),
      ),
      isNull,
    );
  });

  test('mount contract is fail closed until axes and offset are verified', () {
    for (final calibration in [
      const HeadTrackingMountCalibration(),
      const HeadTrackingMountCalibration(
        mount: HeadTrackingCameraMount.fixedWorldCamera,
      ),
      const HeadTrackingMountCalibration(
        mount: HeadTrackingCameraMount.headMountedCamera,
      ),
      const HeadTrackingMountCalibration(
        mount: HeadTrackingCameraMount.handheldPhone,
        axesAlignmentVerified: true,
        cameraAxisOffsetDegrees: 0,
      ),
    ]) {
      expect(
        headTrackedAngleForMount(
          cameraAngle: 10,
          sensor: ready(20),
          now: now,
          calibration: calibration,
        ),
        isNull,
      );
    }
    expect(
      headTrackedAngleForMount(
        cameraAngle: 10,
        sensor: ready(20),
        now: now,
        calibration: const HeadTrackingMountCalibration(
          mount: HeadTrackingCameraMount.fixedWorldCamera,
          axesAlignmentVerified: true,
          cameraAxisOffsetDegrees: 181,
        ),
      ),
      isNull,
    );
  });

  test('fixed camera applies measured axis offset then relative yaw', () {
    expect(
      headTrackedAngleForMount(
        cameraAngle: 10,
        sensor: ready(30),
        now: now,
        calibration: fixed(offset: 5),
      ),
      closeTo(-15, 1e-9),
    );
  });

  test('head mounted camera does not subtract yaw twice', () {
    const calibration = HeadTrackingMountCalibration(
      mount: HeadTrackingCameraMount.headMountedCamera,
      axesAlignmentVerified: true,
      cameraAxisOffsetDegrees: -5,
    );
    expect(
      headTrackedAngleForMount(
        cameraAngle: 20,
        sensor: ready(90),
        now: now,
        calibration: calibration,
      ),
      closeTo(15, 1e-9),
    );
  });

  test('session reset requires reconnect and recalibration', () {
    final state = HeadTrackingState()
      ..publish(ready(10))
      ..resetForSession();
    expect(state.snapshot.status, HeadTrackingStatus.disconnected);
    expect(state.snapshot.referenceYaw, isNull);
  });

  test('calibrateZeroReferenceFromCameraAngle sets reference yaw correctly', () {
    final state = HeadTrackingState()
      ..publish(ready(10)); // filteredYaw = 10 deg

    // Camera detects door at +15 deg (right).
    // Target world yaw = 10 + 15 = 25 deg.
    final locked = state.calibrateZeroReferenceFromCameraAngle(15.0);
    expect(locked, 25.0);
    expect(state.snapshot.referenceYaw, 25.0);
    expect(state.snapshot.message, contains('+15.0°'));

    // Before head turn (filteredYaw = 10 deg):
    // headRight relative to reference (25 deg) = 10 - 25 = -15 deg (head is looking 15 deg left of target).
    final headRight = relativeAngle(state.snapshot.filteredYaw!, state.snapshot.referenceYaw!);
    expect(headRight, -15.0);

    // When head rotates to face target (filteredYaw = 25 deg):
    final headFacingTarget = relativeAngle(25.0, state.snapshot.referenceYaw!);
    expect(headFacingTarget, 0.0);
  });
}

HeadTrackingMountCalibration fixed({double offset = 0}) =>
    HeadTrackingMountCalibration(
      mount: HeadTrackingCameraMount.fixedWorldCamera,
      axesAlignmentVerified: true,
      cameraAxisOffsetDegrees: offset,
    );
