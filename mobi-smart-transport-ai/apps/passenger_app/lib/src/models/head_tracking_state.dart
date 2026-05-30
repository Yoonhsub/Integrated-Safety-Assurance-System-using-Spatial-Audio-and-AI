// V3 Head Tracking State (mock/display only)

enum FacingDirection { front, right, left, rear, unknown }

class HeadTrackingState {
  final bool connected;
  final bool calibrated;
  final double yaw;
  final double pitch;
  final double roll;
  final double relativeYaw;
  final FacingDirection facingDirection;

  const HeadTrackingState({
    required this.connected,
    required this.calibrated,
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.relativeYaw,
    required this.facingDirection,
  });

  static const disconnected = HeadTrackingState(
    connected: false,
    calibrated: false,
    yaw: 0,
    pitch: 0,
    roll: 0,
    relativeYaw: 0,
    facingDirection: FacingDirection.unknown,
  );

  static FacingDirection directionFromRelativeYaw(double relYaw) {
    if (relYaw >= -30 && relYaw <= 30) return FacingDirection.front;
    if (relYaw > 30 && relYaw <= 120) return FacingDirection.right;
    if (relYaw >= -120 && relYaw < -30) return FacingDirection.left;
    return FacingDirection.rear;
  }
}
