// V3 Audio/Haptic Cue Policy

enum CueType {
  none,
  targetBusFar,
  targetBusMid,
  targetBusNear,
  wrongBusNear,
  geofenceWarning,
  danger,
}

class CuePolicy {
  final CueType type;
  final Duration interval;
  final int repeatCount;

  const CuePolicy({
    required this.type,
    required this.interval,
    this.repeatCount = -1,
  });

  static const none = CuePolicy(type: CueType.none, interval: Duration.zero, repeatCount: 0);

  static const targetBusFar = CuePolicy(
    type: CueType.targetBusFar,
    interval: Duration(seconds: 3),
    repeatCount: -1,
  );

  static const targetBusMid = CuePolicy(
    type: CueType.targetBusMid,
    interval: Duration(milliseconds: 1500),
    repeatCount: -1,
  );

  static const targetBusNear = CuePolicy(
    type: CueType.targetBusNear,
    interval: Duration(milliseconds: 600),
    repeatCount: -1,
  );

  static const wrongBusNear = CuePolicy(
    type: CueType.wrongBusNear,
    interval: Duration(seconds: 2),
    repeatCount: 3,
  );

  static const geofenceWarning = CuePolicy(
    type: CueType.geofenceWarning,
    interval: Duration(seconds: 2),
    repeatCount: -1,
  );

  static const danger = CuePolicy(
    type: CueType.danger,
    interval: Duration(milliseconds: 500),
    repeatCount: -1,
  );

  static CuePolicy fromDecision(String decision) {
    switch (decision) {
      case 'TARGET_BUS_FAR':
        return targetBusFar;
      case 'TARGET_BUS_MID':
        return targetBusMid;
      case 'TARGET_BUS_NEAR':
        return targetBusNear;
      case 'WRONG_BUS_NEAR':
        return wrongBusNear;
      case 'GEOFENCE_WARNING':
        return geofenceWarning;
      case 'DANGER':
        return danger;
      default:
        return none;
    }
  }
}
