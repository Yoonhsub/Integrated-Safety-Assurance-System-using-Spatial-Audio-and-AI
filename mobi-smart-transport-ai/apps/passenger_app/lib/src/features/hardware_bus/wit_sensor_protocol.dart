/// WT901BLECL BLE 5.0: 20-byte 55 61 packets, signed little-endian angles.
/// Reference: WITMOTION/WitBluetooth_BWT901BLE5_0 Python device_model.py.
class WitAngles {
  const WitAngles(this.x, this.y, this.z);
  final double x, y, z;
}

double relativeAngle(double angle, double reference) =>
    (angle - reference + 180) % 360 - 180;

class WitSensorDecoder {
  final List<int> _pending = [];

  void reset() => _pending.clear();

  List<WitAngles> add(List<int> bytes) {
    final readings = <WitAngles>[];
    for (final byte in bytes) {
      _pending.add(byte);
      while (_pending.isNotEmpty) {
        if (_pending.first != 0x55) {
          _pending.removeAt(0);
        } else if (_pending.length < 2) {
          break;
        } else if (_pending[1] != 0x61 && _pending[1] != 0x71) {
          _pending.removeAt(0);
        } else if (_pending.length < 20) {
          break;
        } else {
          if (_pending[1] == 0x61) {
            double angle(int offset) {
              var value = _pending[offset] | (_pending[offset + 1] << 8);
              if (value >= 0x8000) value -= 0x10000;
              return value / 32768 * 180;
            }

            readings.add(WitAngles(angle(14), angle(16), angle(18)));
          }
          // 0x71 register responses are also 20 bytes, but aren't angle frames.
          _pending.removeRange(0, 20);
        }
      }
    }
    return readings;
  }
}
