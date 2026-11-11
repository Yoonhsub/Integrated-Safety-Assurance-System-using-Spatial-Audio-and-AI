enum DoorProximity { approaching, near, unknown }

enum DoorRisk { none, caution, danger }

enum DoorPhase {
  stopped,
  unavailable,
  warning,
  awaitingTarget,
  approaching,
  near,
  arrived
}

class DoorObstacle {
  const DoorObstacle(this.id, this.risk, {this.pan});
  final String id;
  final DoorRisk risk;
  // Screen-relative stereo only. null means unknown, rendered centrally.
  final double? pan;
}

class DoorGuidance {
  const DoorGuidance(this.phase, this.text, {this.pan});
  final DoorPhase phase;
  final String text;
  final double? pan;
  bool get approaching =>
      phase == DoorPhase.approaching || phase == DoorPhase.near;
  String get key => '$phase|$text|$pan';
}

/// Demo interlock, not a vehicle identity, door-open or boarding-safety decision.
/// All observations and ticks use the same monotonic session clock. Producers
/// must retain capture time, supply full obstacle snapshots and reject replay.
class DoorApproachGuard {
  DoorApproachGuard(
      {required this.targetId,
      this.targetTtl = const Duration(seconds: 3),
      this.perceptionTtl = const Duration(seconds: 2)}) {
    if (targetId.trim().isEmpty ||
        targetTtl <= Duration.zero ||
        perceptionTtl <= Duration.zero) {
      throw ArgumentError('Target ID and positive freshness bounds required');
    }
  }
  final String targetId;
  final Duration targetTtl, perceptionTtl;
  Duration? _now, _targetAt, _perceptionAt, _resumeAfter;
  DoorProximity _proximity = DoorProximity.unknown;
  List<DoorObstacle> _obstacles = const [];
  bool _armed = false, _arrived = false, _invalidPerception = false;
  bool _interrupted = false;
  bool _clockFault = false;
  DoorGuidance current = const DoorGuidance(DoorPhase.stopped, '안내 중지');

  bool _clock(Duration now) {
    if (_clockFault || now.isNegative || (_now != null && now < _now!)) {
      _clockFault = true;
      _armed = false;
      current = const DoorGuidance(DoorPhase.stopped, '시각 기준 오류 · 새 세션이 필요합니다');
      return false;
    }
    _now = now;
    return true;
  }

  bool _fresh(Duration? at, Duration ttl, Duration now) =>
      at != null && now >= at && now - at < ttl;

  void start(Duration now) {
    if (!_clock(now) || _arrived) return;
    _armed = true;
    tick(now);
  }

  void stop(Duration now) {
    if (!_clock(now)) return;
    _armed = false;
    _resumeAfter = now;
    tick(now);
  }

  bool observeTarget(
      {required String id,
      required Duration at,
      required Duration now,
      required DoorProximity proximity}) {
    if (!_clock(now) ||
        id != targetId ||
        at.isNegative ||
        at > now ||
        now - at >= targetTtl ||
        (_targetAt != null && at <= _targetAt!)) {
      return false;
    }
    _targetAt = at;
    _proximity = proximity;
    tick(now);
    return true;
  }

  bool observeObstacles(
      {required Duration at,
      required Duration now,
      required Iterable<DoorObstacle> obstacles}) {
    if (!_clock(now)) return false;
    if (at.isNegative ||
        at > now ||
        now - at >= perceptionTtl ||
        (_perceptionAt != null && at <= _perceptionAt!)) {
      return false;
    }
    final values = obstacles.take(65).toList();
    final ids = <String>{};
    final invalid = values.length > 64 ||
        values.any((o) =>
            o.id.trim().isEmpty ||
            !ids.add(o.id) ||
            (o.pan != null && (!o.pan!.isFinite || o.pan!.abs() > 1)));
    final wasUnknown =
        _invalidPerception || !_fresh(_perceptionAt, perceptionTtl, now);
    final hadRisk = _obstacles.any((o) => o.risk != DoorRisk.none);
    _perceptionAt = at;
    _invalidPerception = invalid;
    _obstacles = invalid ? const [] : values;
    if ((hadRisk || wasUnknown) &&
        !_obstacles.any((o) => o.risk != DoorRisk.none)) {
      // A target observed DURING the warning cannot authorize resumption.
      _resumeAfter = now;
    }
    tick(now);
    return !invalid;
  }

  DoorGuidance tick(Duration now) {
    if (!_clock(now)) return current;
    if (_arrived) {
      return current = const DoorGuidance(DoorPhase.arrived, '시연자가 도착을 확인했습니다');
    }
    if (!_armed) {
      return current = const DoorGuidance(DoorPhase.stopped, '안내 중지');
    }
    if (_invalidPerception || !_fresh(_perceptionAt, perceptionTtl, now)) {
      _interrupted = true;
      _resumeAfter = now;
      return current =
          const DoorGuidance(DoorPhase.unavailable, '주변 위험 정보를 다시 확인해 주세요');
    }
    final hazards = _obstacles.where((o) => o.risk != DoorRisk.none).toList()
      ..sort((a, b) {
        final risk = b.risk.index.compareTo(a.risk.index);
        return risk != 0 ? risk : a.id.compareTo(b.id);
      });
    if (hazards.isNotEmpty) {
      _interrupted = true;
      _resumeAfter = now;
      final hazard = hazards.first;
      return current = DoorGuidance(DoorPhase.warning,
          '${hazard.risk == DoorRisk.danger ? '위험' : '주의'} · 장애물 ${hazard.id}',
          pan: hazard.pan ?? 0);
    }
    if (!_fresh(_targetAt, targetTtl, now) ||
        _proximity == DoorProximity.unknown) {
      _interrupted = true;
      _resumeAfter = now;
      return current =
          const DoorGuidance(DoorPhase.unavailable, '탑승 위치를 다시 확인해 주세요');
    }
    if (_interrupted || _resumeAfter != null) {
      if (_targetAt! <= _resumeAfter!) {
        return current =
            const DoorGuidance(DoorPhase.awaitingTarget, '새 목표 비콘 관측을 기다립니다');
      }
      _interrupted = false;
      _resumeAfter = null;
    }
    return current = _proximity == DoorProximity.near
        ? const DoorGuidance(DoorPhase.near, '탑승 위치 근처입니다. 문과 발밑을 확인해 주세요')
        : const DoorGuidance(DoorPhase.approaching, '탑승 위치에 접근 중입니다');
  }

  bool confirmArrival(Duration now) {
    if (tick(now).phase != DoorPhase.near) return false;
    _arrived = true;
    _armed = false;
    tick(now);
    return true;
  }
}
