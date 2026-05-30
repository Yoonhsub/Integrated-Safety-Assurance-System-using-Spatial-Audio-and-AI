// V3 Head Tracking Service (mock display only — real sensor integration is 2학기 scope)
import '../models/head_tracking_state.dart';

class HeadTrackingService {
  double _baseYaw = 0;
  double _currentYaw = 0;
  double _pitch = 0;
  double _roll = 0;
  bool _calibrated = false;

  HeadTrackingState get state {
    final relYaw = _currentYaw - _baseYaw;
    return HeadTrackingState(
      connected: false,
      calibrated: _calibrated,
      yaw: _currentYaw,
      pitch: _pitch,
      roll: _roll,
      relativeYaw: relYaw,
      facingDirection: HeadTrackingState.directionFromRelativeYaw(relYaw),
    );
  }

  void calibrate() {
    _baseYaw = _currentYaw;
    _calibrated = true;
  }

  void updateMock({double yaw = 0, double pitch = 0, double roll = 0}) {
    _currentYaw = yaw;
    _pitch = pitch;
    _roll = roll;
  }
}
