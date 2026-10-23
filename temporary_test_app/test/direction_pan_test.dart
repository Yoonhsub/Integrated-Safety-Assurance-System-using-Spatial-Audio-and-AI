import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_ble_temp/direction_pan.dart';

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
      expect(p.left * p.left + p.right * p.right, closeTo(1, 1e-9));
    }
  });
  test('invalid angles cannot create an audio gain', () {
    expect(() => DirectionPan.fromZ(double.nan, 0), throwsArgumentError);
    expect(() => DirectionPan.fromZ(0, double.infinity), throwsArgumentError);
  });
}
