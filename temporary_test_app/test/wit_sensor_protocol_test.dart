import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_ble_temp/wit_sensor_protocol.dart';

List<int> frame(int x, int y, int z) {
  final data = List<int>.filled(20, 0)
    ..[0] = 0x55
    ..[1] = 0x61;
  for (final entry in {14: x, 16: y, 18: z}.entries) {
    data[entry.key] = entry.value & 255;
    data[entry.key + 1] = (entry.value >> 8) & 255;
  }
  return data;
}

void main() {
  test('decodes signed little-endian angles and full-scale bounds', () {
    final result = WitSensorDecoder().add(frame(16384, -16384, -32768)).single;
    expect(result.x, 90);
    expect(result.y, -90);
    expect(result.z, -180);
    expect(
      WitSensorDecoder().add(frame(32767, 0, 0)).single.x,
      closeTo(180, 0.006),
    );
  });
  test('accepts fragmented/combined packets and skips junk', () {
    final decoder = WitSensorDecoder();
    final bytes = frame(100, 200, 300);
    expect(decoder.add([0, 0x55, 0, ...bytes.take(9)]), isEmpty);
    final readings = decoder.add([
      ...bytes.skip(9),
      ...frame(-100, -200, -300),
    ]);
    expect(readings.length, 2);
    expect(readings.first.z, closeTo(300 / 32768 * 180, 0.0001));
    expect(readings.last.z, closeTo(-300 / 32768 * 180, 0.0001));
  });
  test('skips 0x71 register packets including angle-like payload bytes', () {
    final register = List<int>.filled(20, 0)
      ..[0] = 0x55
      ..[1] = 0x71
      ..[6] = 0x55
      ..[7] = 0x61;
    final readings = WitSensorDecoder().add([
      ...register,
      ...frame(0, 0, 16384),
    ]);
    expect(readings.length, 1);
    expect(readings.single.z, 90);
  });
  test('reset does not join an old connection fragment with a new packet', () {
    final decoder = WitSensorDecoder();
    decoder.add(frame(1, 2, 3).take(10).toList());
    decoder.reset();
    expect(decoder.add(frame(0, 0, -16384)).single.z, -90);
  });
  test('relative angle wraps across the +/-180 boundary', () {
    expect(relativeAngle(-179, 179), 2);
    expect(relativeAngle(179, -179), -2);
    expect(relativeAngle(15, 15), 0);
  });
}
