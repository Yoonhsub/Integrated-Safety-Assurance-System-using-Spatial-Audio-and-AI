import 'package:flutter/foundation.dart';
import '../features/hardware_bus/wit_sensor_protocol.dart';

enum HeadTrackingStatus {
  disconnected,
  connecting,
  connectedUncalibrated,
  ready,
  stale,
  error,
}

/// The physical relationship between the camera and the WT901 sensor.
///
/// Selecting a value is not proof that the mount has been measured. The
/// separate [HeadTrackingMountCalibration.axesAlignmentVerified] gate remains
/// fail-closed until a person verifies the real axes and offset.
enum HeadTrackingCameraMount {
  unverified,
  fixedWorldCamera,
  headMountedCamera,
  handheldPhone,
}

@immutable
class HeadTrackingMountCalibration {
  const HeadTrackingMountCalibration({
    this.mount = HeadTrackingCameraMount.unverified,
    this.axesAlignmentVerified = false,
    this.cameraAxisOffsetDegrees,
  });

  final HeadTrackingCameraMount mount;
  final bool axesAlignmentVerified;

  /// Measured horizontal camera optical-axis offset in the sensor/head frame.
  /// Positive is right, matching the bbox and native HRTF convention.
  final double? cameraAxisOffsetDegrees;

  bool get supportsHeadTrackedCue =>
      mount == HeadTrackingCameraMount.fixedWorldCamera ||
      mount == HeadTrackingCameraMount.headMountedCamera;

  bool get verified =>
      supportsHeadTrackedCue &&
      axesAlignmentVerified &&
      cameraAxisOffsetDegrees?.isFinite == true &&
      cameraAxisOffsetDegrees!.abs() <= 180;
}

@immutable
class HeadTrackingSnapshot {
  const HeadTrackingSnapshot({
    required this.status,
    this.rawYaw,
    this.filteredYaw,
    this.referenceYaw,
    this.receivedAt,
    this.message = '',
  });

  final HeadTrackingStatus status;
  final double? rawYaw, filteredYaw, referenceYaw;
  final DateTime? receivedAt;
  final String message;

  Duration? age(DateTime now) =>
      receivedAt == null ? null : now.toUtc().difference(receivedAt!.toUtc());

  bool usable(
    DateTime now, {
    Duration maximumAge = const Duration(seconds: 2),
  }) {
    final sampleAge = age(now);
    return status == HeadTrackingStatus.ready &&
        filteredYaw?.isFinite == true &&
        referenceYaw?.isFinite == true &&
        sampleAge != null &&
        !sampleAge.isNegative &&
        sampleAge < maximumAge;
  }
}

/// Shared read-only state contract. The existing WT901 panel remains the only
/// BLE owner; tests may inject samples through a separate controller instance.
class HeadTrackingState extends ChangeNotifier {
  HeadTrackingSnapshot _snapshot = const HeadTrackingSnapshot(
    status: HeadTrackingStatus.disconnected,
  );
  HeadTrackingSnapshot get snapshot => _snapshot;

  void publish(HeadTrackingSnapshot value) {
    _snapshot = value;
    notifyListeners();
  }

  /// Sets the zero-reference yaw using an optical camera target angle.
  ///
  /// When a vision model detects a target (such as `bus_door`) at [cameraAngle],
  /// the target's absolute azimuth in the world frame is:
  /// `worldTargetYaw = currentRawYaw + cameraAngle`.
  ///
  /// Locking this as [referenceYaw] anchors the target at 0° in the user's
  /// relative spatial audio frame, allowing continuous HRTF tracking as the
  /// user rotates their head. Returns the newly locked reference yaw, or null
  /// if the sensor is not currently reporting usable yaw data.
  double? calibrateZeroReferenceFromCameraAngle(double cameraAngle) {
    if (!cameraAngle.isFinite) return null;
    final currentRaw = _snapshot.filteredYaw ?? _snapshot.rawYaw;
    if (currentRaw == null || !currentRaw.isFinite) return null;

    final newRef = relativeAngle(currentRaw, -cameraAngle);
    publish(
      HeadTrackingSnapshot(
        status: _snapshot.status,
        rawYaw: _snapshot.rawYaw,
        filteredYaw: _snapshot.filteredYaw,
        referenceYaw: newRef,
        receivedAt: DateTime.now().toUtc(),
        message: '카메라 비전 객체 각도(${cameraAngle >= 0 ? '+' : ''}${cameraAngle.toStringAsFixed(1)}°) 기준 영점 보정 완료',
      ),
    );
    return newRef;
  }

  void resetForSession() => publish(
    const HeadTrackingSnapshot(
      status: HeadTrackingStatus.disconnected,
      message: '새 세션 · 센서 재연결 및 정면 보정 필요',
    ),
  );
}

final sharedHeadTrackingState = HeadTrackingState();

double horizontalAngleForNormalizedBbox({
  required double x,
  required double width,
  required double horizontalFovDegrees,
}) {
  if (![x, width, horizontalFovDegrees].every((v) => v.isFinite) ||
      x < 0 ||
      width <= 0 ||
      x + width > 1.000000001 ||
      horizontalFovDegrees <= 0 ||
      horizontalFovDegrees >= 180) {
    throw ArgumentError('Valid normalized bbox and horizontal FOV required');
  }
  final center = x + width / 2;
  // Positive angles point right, matching DirectionPan/ToneTestEngine.
  return (center - .5) * horizontalFovDegrees;
}

double? headTrackedAngleForMount({
  required double cameraAngle,
  required HeadTrackingSnapshot sensor,
  required DateTime now,
  required HeadTrackingMountCalibration calibration,
}) {
  if (!cameraAngle.isFinite || !sensor.usable(now) || !calibration.verified) {
    return null;
  }
  final alignedCameraAngle = relativeAngle(
    cameraAngle,
    -(calibration.cameraAxisOffsetDegrees!),
  );

  // A head-mounted camera already reports an object in a head-relative image
  // frame. Subtracting yaw here would double-compensate it. A fresh READY
  // sample is still required as a lifecycle/declared-mount validity signal;
  // this mode is not represented as world-fixed audio.
  if (calibration.mount == HeadTrackingCameraMount.headMountedCamera) {
    return alignedCameraAngle;
  }
  if (calibration.mount != HeadTrackingCameraMount.fixedWorldCamera) {
    return null;
  }
  final headRight = relativeAngle(sensor.filteredYaw!, sensor.referenceYaw!);
  return relativeAngle(alignedCameraAngle, headRight);
}
