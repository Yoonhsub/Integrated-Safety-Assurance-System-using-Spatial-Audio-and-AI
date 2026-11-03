import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/direction_pan.dart';

void main() {
  test(
    'front target is balanced and a right head turn puts it on the left',
    () {
      final front = DirectionPan.fromZ(20, 20);
      expect(front.pan, closeTo(0, 1e-9));
      expect(front.left, closeTo(front.right, 1e-9));
      final rightTurn = DirectionPan.fromZ(110, 20);
      expect(rightTurn.targetAngle, -90);
      expect(rightTurn.left, closeTo(1, 1e-9));
      expect(rightTurn.right, closeTo(0, 1e-9));
      final leftTurn = DirectionPan.fromZ(-70, 20);
      expect(leftTurn.right, closeTo(1, 1e-9));
    },
  );
  test('reversal and wrap preserve bounded constant-power gains', () {
    expect(DirectionPan.fromZ(90, 0, reverse: true).right, closeTo(1, 1e-9));
    expect(DirectionPan.fromZ(-179, 179).targetAngle, -2);
    for (var angle = -720; angle <= 720; angle++) {
      final p = DirectionPan.fromZ(angle.toDouble(), 13);
      expect(p.left, inInclusiveRange(0, 1));
      expect(p.right, inInclusiveRange(0, 1));
      expect(
        p.left * p.left + p.right * p.right,
        closeTo(p.supported ? 1 : 0, 1e-9),
      );
    }
  });
  test('invalid angles cannot create an audio gain', () {
    expect(() => DirectionPan.fromZ(double.nan, 0), throwsArgumentError);
    expect(() => DirectionPan.fromZ(0, double.infinity), throwsArgumentError);
  });
  test('five-way boundaries and object minus head correction', () {
    for (final cue in FiveWayCue.values) {
      final p = DirectionPan.fromZ(0, 0, objectAngle: cue.angle);
      expect(p.cue, cue);
      expect(p.supported, isTrue);
    }
    expect(
      DirectionPan.fromZ(45, 0, objectAngle: 90).cue,
      FiveWayCue.frontRight,
    );
    expect(DirectionPan.fromZ(0, 0, objectAngle: -22.5).cue, FiveWayCue.front);
    expect(
      DirectionPan.fromZ(0, 0, objectAngle: -22.51).cue,
      FiveWayCue.frontLeft,
    );
    expect(DirectionPan.fromZ(0, 0, objectAngle: 67.51).cue, FiveWayCue.right);
    expect(DirectionPan.fromZ(0, 0, objectAngle: 95.01).supported, isFalse);
    final rear = DirectionPan.fromZ(180, 0);
    expect(rear.left, 0);
    expect(rear.right, 0);
    expect(
      () => DirectionPan.fromZ(0, 0, objectAngle: double.nan),
      throwsArgumentError,
    );
  });
  test('yaw filter smooths shortest arc and resets after stale input', () {
    final f = YawFilter();
    expect(f.add(179, Duration.zero), 179);
    final wrapped = f.add(-179, const Duration(milliseconds: 80));
    expect(wrapped.abs(), greaterThan(178));
    expect(f.add(0, const Duration(milliseconds: 80)), wrapped);
    expect(f.add(45, const Duration(seconds: 2)), 45);
    f.reset();
    expect(f.add(0, Duration.zero), 0);
    final smooth = f.add(90, const Duration(milliseconds: 80));
    expect(smooth, inExclusiveRange(0, 90));
    expect(
      () => f.add(double.nan, const Duration(seconds: 3)),
      throwsArgumentError,
    );
  });
  test('side targets stay playable despite small yaw drift on either side', () {
    for (final target in [-90.0, 90.0]) {
      for (final yaw in [-5.0, -0.1, 0.0, 0.1, 5.0]) {
        final p = DirectionPan.fromZ(yaw, 0, objectAngle: target);
        expect(p.supported, isTrue);
        expect(p.cue, target < 0 ? FiveWayCue.left : FiveWayCue.right);
      }
    }
    expect(DirectionPan.fromZ(5.01, 0, objectAngle: -90).supported, isFalse);
    expect(DirectionPan.fromZ(-5.01, 0, objectAngle: 90).supported, isFalse);
  });
}
