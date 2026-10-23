import 'dart:math' as math;
import 'wit_sensor_protocol.dart';

class DirectionPan {
  const DirectionPan(this.targetAngle, this.pan, this.left, this.right);
  final double targetAngle, pan, left, right;

  factory DirectionPan.fromZ(
    double z,
    double reference, {
    bool reverse = false,
  }) {
    if (!z.isFinite || !reference.isFinite) {
      throw ArgumentError('Finite sensor angles required');
    }
    final headRight = relativeAngle(z, reference) * (reverse ? -1 : 1);
    final target = relativeAngle(0, headRight);
    final pan = math.sin(target * math.pi / 180).clamp(-1.0, 1.0);
    final theta = (pan + 1) * math.pi / 4;
    return DirectionPan(target, pan, math.cos(theta), math.sin(theta));
  }
}
