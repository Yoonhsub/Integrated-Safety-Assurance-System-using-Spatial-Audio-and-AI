import 'dart:math' as math;
import 'wit_sensor_protocol.dart';

/// Positive angles point right. Rear targets have no supported five-way cue.
enum FiveWayCue {
  left('LEFT', '왼쪽', -90),
  frontLeft('FRONT-LEFT', '왼쪽 앞', -45),
  front('FRONT', '정면', 0),
  frontRight('FRONT-RIGHT', '오른쪽 앞', 45),
  right('RIGHT', '오른쪽', 90);

  const FiveWayCue(this.code, this.label, this.angle);
  final String code, label;
  final double angle;
}

/// Time-based shortest-arc low-pass filter, applied once per sensor frame.
class YawFilter {
  YawFilter({this.timeConstant = const Duration(milliseconds: 80)});
  final Duration timeConstant;
  double? _value;
  Duration? _time;
  void reset() {
    _value = null;
    _time = null;
  }

  double add(double yaw, Duration time) {
    if (!yaw.isFinite || time.isNegative || timeConstant.inMicroseconds <= 0) {
      throw ArgumentError(
        'Valid yaw, monotonic time and positive filter constant required',
      );
    }
    final previousTime = _time;
    if (previousTime != null && time <= previousTime) return _value!;
    final dt = previousTime == null ? null : time - previousTime;
    if (_value == null || dt! > const Duration(seconds: 1)) {
      _value = relativeAngle(yaw, 0);
    } else {
      final alpha =
          1 - math.exp(-dt.inMicroseconds / timeConstant.inMicroseconds);
      _value = relativeAngle(_value! + alpha * relativeAngle(yaw, _value!), 0);
    }
    _time = time;
    return _value!;
  }
}

class DirectionPan {
  const DirectionPan(
    this.targetAngle,
    this.pan,
    this.left,
    this.right, {
    this.cue = FiveWayCue.front,
    this.supported = true,
  });
  final double targetAngle, pan, left, right;
  final FiveWayCue cue;
  final bool supported;

  factory DirectionPan.fromZ(
    double z,
    double reference, {
    bool reverse = false,
    double objectAngle = 0,
  }) {
    if (!z.isFinite || !reference.isFinite || !objectAngle.isFinite) {
      throw ArgumentError('Finite sensor and object angles required');
    }
    final headRight = relativeAngle(z, reference) * (reverse ? -1 : 1);
    final target = relativeAngle(objectAngle, headRight);
    // Allow five degrees of calibration noise at the side boundaries.
    final supported = target.abs() <= 95;
    final cue = target < -67.5
        ? FiveWayCue.left
        : target < -22.5
        ? FiveWayCue.frontLeft
        : target <= 22.5
        ? FiveWayCue.front
        : target <= 67.5
        ? FiveWayCue.frontRight
        : FiveWayCue.right;
    // Five fixed stereo balances; these do not synthesize HRTF/front-back cues.
    final pan = cue.angle / 90;
    final theta = (pan + 1) * math.pi / 4;
    return DirectionPan(
      target,
      pan,
      supported ? math.cos(theta) : 0,
      supported ? math.sin(theta) : 0,
      cue: cue,
      supported: supported,
    );
  }
}

/// Stateful five-way deadband. Reset when target or calibration changes.
class DirectionCueTracker {
  DirectionCueTracker({this.hysteresisDegrees = 3}) {
    if (!hysteresisDegrees.isFinite ||
        hysteresisDegrees < 0 ||
        hysteresisDegrees >= 22.5) {
      throw ArgumentError('Hysteresis must be between 0 and 22.5 degrees');
    }
  }
  final double hysteresisDegrees;
  FiveWayCue? _previous;
  void reset() => _previous = null;

  DirectionPan track(DirectionPan raw) {
    if (!raw.supported) {
      reset();
      return raw;
    }
    var cue = raw.cue;
    final previous = _previous;
    if (previous != null) {
      final lower = previous == FiveWayCue.left ? -95.0 : previous.angle - 22.5;
      final upper = previous == FiveWayCue.right ? 95.0 : previous.angle + 22.5;
      if (raw.targetAngle >= lower - hysteresisDegrees &&
          raw.targetAngle <= upper + hysteresisDegrees) {
        cue = previous;
      }
    }
    _previous = cue;
    final pan = cue.angle / 90;
    final theta = (pan + 1) * math.pi / 4;
    return DirectionPan(
      raw.targetAngle,
      pan,
      math.cos(theta),
      math.sin(theta),
      cue: cue,
    );
  }
}
