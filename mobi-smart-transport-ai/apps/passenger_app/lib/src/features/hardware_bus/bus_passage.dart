enum BusPassagePhase { approaching, stopped, departing }

/// Scenario assumption: left approach, stop in front, depart right.
/// RSSI cannot measure bearing, speed, boarding or true stop position.
class BusPassage {
  BusPassagePhase phase = BusPassagePhase.approaching;
  int? _peak;
  Duration? _last, _nearSince, _fallSince;
  int _nearCount = 0, _fallCount = 0;
  double angle = -90;

  void reset() {
    phase = BusPassagePhase.approaching;
    _peak = null;
    _last = _nearSince = _fallSince = null;
    _nearCount = _fallCount = 0;
    angle = -90;
  }

  void observe(int rssi, Duration at) {
    if (rssi < -120 || rssi > 0 || at.isNegative) {
      throw ArgumentError('Invalid BLE sample');
    }
    if (_last != null && at <= _last!) return;
    if (_last != null && at - _last! >= const Duration(seconds: 3)) reset();
    _last = at;
    if (_peak == null || rssi > _peak!) _peak = rssi;
    if (phase == BusPassagePhase.approaching) {
      if (rssi >= -55) {
        _nearSince ??= at;
        _nearCount++;
        if (_nearCount >= 3 &&
            at - _nearSince! >= const Duration(milliseconds: 1500)) {
          phase = BusPassagePhase.stopped;
          _peak = rssi;
        }
      } else {
        _nearSince = null;
        _nearCount = 0;
      }
    } else if (phase == BusPassagePhase.stopped) {
      if (rssi <= _peak! - 8) {
        _fallSince ??= at;
        _fallCount++;
        if (_fallCount >= 3 &&
            at - _fallSince! >= const Duration(milliseconds: 800)) {
          phase = BusPassagePhase.departing;
        }
      } else {
        _fallSince = null;
        _fallCount = 0;
      }
    }
    if (phase == BusPassagePhase.approaching) {
      angle = -90 + 60 * ((rssi + 85) / 30).clamp(0.0, 1.0);
    } else if (phase == BusPassagePhase.stopped) {
      angle = 0;
    } else {
      angle = 30 + 60 * ((_peak! - rssi - 8) / 17).clamp(0.0, 1.0);
    }
  }

  String get label => switch (phase) {
        BusPassagePhase.approaching => '버스 접근 (추정)',
        BusPassagePhase.stopped => '버스 정차 (추정)',
        BusPassagePhase.departing => '오른쪽으로 출발 (추정)',
      };
}
