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

  const headMount = HeadTrackingMountCalibration(
    mount: HeadTrackingCameraMount.headMountedCamera,
    axesAlignmentVerified: true,
    cameraAxisOffsetDegrees: 5,
  );
  double? calibrate(
    HeadTrackingState state,
    double angle, {
    HeadTrackingMountCalibration mount = headMount,
    double fov = 90,
    DateTime? capturedAt,
  }) => state.calibrateZeroReferenceFromCameraAngle(
    angle,
    calibration: mount,
    horizontalFovDegrees: fov,
    cameraCapturedAt: capturedAt ?? state.snapshot.receivedAt ?? now,
    now: now,
  );

  test(
    'camera calibration preserves sample time and applies measured axes',
    () {
      final state = HeadTrackingState()..publish(ready(10));
      final original = state.snapshot;
      expect(calibrate(state, 15), 30); // yaw 10 + optical 15 + offset 5
      expect(state.snapshot.receivedAt, original.receivedAt);
      expect(state.snapshot.status, original.status);
      expect(state.snapshot.filteredYaw, original.filteredYaw);
      expect(state.snapshot.rawYaw, original.rawYaw);
      expect(state.snapshot.usable(now), isTrue);
      expect(
        state.snapshot.usable(now.add(const Duration(seconds: 2))),
        isFalse,
      );
      expect(relativeAngle(30, state.snapshot.referenceYaw!), 0);
      // Head-mounted rendering must not subtract yaw a second time.
      expect(
        headTrackedAngleForMount(
          cameraAngle: 15,
          sensor: state.snapshot,
          now: now,
          calibration: headMount,
        ),
        20,
      );
      state.dispose();
    },
  );

  for (final status in HeadTrackingStatus.values.where(
    (s) => s != HeadTrackingStatus.ready,
  )) {
    test('camera calibration rejects $status without publishing', () {
      final state = HeadTrackingState()
        ..publish(
          HeadTrackingSnapshot(
            status: status,
            rawYaw: 10,
            filteredYaw: 10,
            referenceYaw: 0,
            receivedAt: now,
          ),
        );
      final original = state.snapshot;
      var notifications = 0;
      state.addListener(() => notifications++);
      expect(calibrate(state, 15), isNull);
      expect(identical(state.snapshot, original), isTrue);
      expect(notifications, 0);
      state.dispose();
    });
  }
  for (final age in [
    const Duration(seconds: 10),
    const Duration(seconds: 2),
    const Duration(milliseconds: -1),
  ]) {
    test('camera calibration rejects expired or future sample $age', () {
      final state = HeadTrackingState()
        ..publish(
          HeadTrackingSnapshot(
            status: HeadTrackingStatus.ready,
            rawYaw: 10,
            filteredYaw: 10,
            referenceYaw: 0,
            receivedAt: now.subtract(age),
          ),
        );
      final original = state.snapshot;
      expect(calibrate(state, 15), isNull);
      expect(identical(state.snapshot, original), isTrue);
      expect(state.snapshot.usable(now), isFalse);
      state.dispose();
    });
  }
  test('camera calibration rejects missing time and invalid yaw/reference', () {
    for (final sample in [
      const HeadTrackingSnapshot(
        status: HeadTrackingStatus.ready,
        filteredYaw: 10,
        referenceYaw: 0,
      ),
      HeadTrackingSnapshot(
        status: HeadTrackingStatus.ready,
        rawYaw: 10,
        referenceYaw: 0,
        receivedAt: now,
      ),
      HeadTrackingSnapshot(
        status: HeadTrackingStatus.ready,
        filteredYaw: double.nan,
        referenceYaw: 0,
        receivedAt: now,
      ),
      HeadTrackingSnapshot(
        status: HeadTrackingStatus.ready,
        filteredYaw: 10,
        receivedAt: now,
      ),
    ]) {
      final state = HeadTrackingState()..publish(sample);
      expect(calibrate(state, 15), isNull);
      expect(identical(state.snapshot, sample), isTrue);
      state.dispose();
    }
  });
  test('camera calibration rejects unverified and incompatible mounts', () {
    final state = HeadTrackingState()..publish(ready(10));
    final original = state.snapshot;
    for (final mount in [
      const HeadTrackingMountCalibration(),
      fixed(),
      const HeadTrackingMountCalibration(
        mount: HeadTrackingCameraMount.handheldPhone,
        axesAlignmentVerified: true,
        cameraAxisOffsetDegrees: 0,
      ),
      const HeadTrackingMountCalibration(
        mount: HeadTrackingCameraMount.headMountedCamera,
        cameraAxisOffsetDegrees: 0,
      ),
      const HeadTrackingMountCalibration(
        mount: HeadTrackingCameraMount.headMountedCamera,
        axesAlignmentVerified: true,
      ),
    ]) {
      expect(calibrate(state, 15, mount: mount), isNull);
      expect(identical(state.snapshot, original), isTrue);
    }
    state.dispose();
  });
  test('camera calibration rejects invalid FOV, angles and unpaired frame', () {
    final state = HeadTrackingState()..publish(ready(10));
    final original = state.snapshot;
    for (final fov in [0.0, 180.0, double.nan, double.infinity]) {
      expect(calibrate(state, 15, fov: fov), isNull);
    }
    for (final angle in [46.0, -46.0, double.nan, double.infinity]) {
      expect(calibrate(state, angle), isNull);
    }
    expect(calibrate(state, 15, capturedAt: now), isNull);
    expect(identical(state.snapshot, original), isTrue);
    state.dispose();
  });
  test('camera reference wraps without extending sensor lifetime', () {
    final state = HeadTrackingState()..publish(ready(170));
    final timestamp = state.snapshot.receivedAt;
    expect(calibrate(state, 15), -170);
    expect(calibrate(state, 15), -170);
    expect(state.snapshot.receivedAt, timestamp);
    state.dispose();
  });
}

HeadTrackingMountCalibration fixed({double offset = 0}) =>
    HeadTrackingMountCalibration(
      mount: HeadTrackingCameraMount.fixedWorldCamera,
      axesAlignmentVerified: true,
      cameraAxisOffsetDegrees: offset,
    );
