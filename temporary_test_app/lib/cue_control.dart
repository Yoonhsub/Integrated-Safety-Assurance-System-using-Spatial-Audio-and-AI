import 'direction_pan.dart';

// Local prototype types. These are not the team's Vision/Context contracts.
enum CueObjectKind { target, obstacle, irrelevant }

enum CueDistance { near, medium, far }

enum CueContext { waiting, walking, boarding, complete }

enum CueAction { play, update, stop, none }

class CueObject {
  const CueObject({
    required this.id,
    required this.kind,
    required this.distance,
    required this.angleDegrees,
    required this.observedAt,
  });
  final String id;
  final CueObjectKind kind;
  final CueDistance distance;

  /// Direction in the calibrated world frame; positive is right.
  final double angleDegrees;

  /// Monotonic session elapsed time, not a wall-clock timestamp.
  final Duration observedAt;
}

class CueSelection {
  const CueSelection(this.object, this.priority, this.direction);
  final CueObject object;
  final int priority;
  final DirectionPan direction;
  Duration get repeatInterval => Duration(
    milliseconds: priority >= 3
        ? 500
        : priority == 2
        ? 1000
        : 1500,
  );
  bool sameOutput(CueSelection other) =>
      object.id == other.object.id &&
      object.kind == other.object.kind &&
      priority == other.priority &&
      direction.cue == other.direction.cue;
}

class CueDecision {
  const CueDecision(this.action, this.selection, this.reason);
  final CueAction action;
  final CueSelection? selection;
  final String reason;
}

/// A snapshot is authoritative: absent objects are cleared, never queued.
/// Pure local policy + deterministic single-output state; does not play audio.
class CueController {
  CueController({
    this.targetTtl = const Duration(seconds: 3),
    this.riskTtl = const Duration(seconds: 2),
    this.restartCooldown = const Duration(milliseconds: 800),
  }) {
    if (targetTtl <= Duration.zero ||
        riskTtl <= Duration.zero ||
        restartCooldown.isNegative) {
      throw ArgumentError('Positive TTL and nonnegative cooldown required');
    }
  }
  final Duration targetTtl, riskTtl, restartCooldown;
  final _tracker = DirectionCueTracker();
  CueSelection? _active;
  String? _lastStartedId;
  Duration? _lastStartedAt, _lastNow;
  bool _enabled = true;
  CueSelection? get active => _active;

  CueDecision cancel() {
    _enabled = false;
    return _clear('cancelled; explicit resume required');
  }

  void resume() {
    _enabled = true;
  }

  /// Stop the output before reset; resets monotonic session time and cooldown.
  CueDecision reset() {
    final result = _clear('session reset');
    _lastStartedAt = _lastNow = null;
    _lastStartedId = null;
    _enabled = false;
    return result;
  }

  CueDecision _clear(String reason) {
    final wasActive = _active != null;
    _active = null;
    _tracker.reset();
    return CueDecision(
      wasActive ? CueAction.stop : CueAction.none,
      null,
      reason,
    );
  }

  int _priority(CueObject object, CueContext context) {
    if (object.kind == CueObjectKind.irrelevant ||
        context == CueContext.complete) {
      return 0;
    }
    if (object.kind == CueObjectKind.target) return 1;
    if (object.distance == CueDistance.far) return 0;
    final moving =
        context == CueContext.walking || context == CueContext.boarding;
    if (object.distance == CueDistance.near) return moving ? 3 : 2;
    return moving ? 2 : 0;
  }

  CueDecision tick({
    required Duration now,
    required CueContext context,
    required Iterable<CueObject> objects,
    required double headYaw,
    double reference = 0,
    bool reverse = false,
    bool inputReady = true,
  }) {
    if (now.isNegative || (_lastNow != null && now < _lastNow!)) {
      throw ArgumentError('Use monotonically increasing session time');
    }
    _lastNow = now;
    if (!_enabled || !inputReady || !headYaw.isFinite || !reference.isFinite) {
      return _clear('disabled or invalid head input');
    }
    // Bound even a lazy/infinite external iterable; no unbounded event cache.
    final snapshot = objects.take(65).toList();
    if (snapshot.length > 64) return _clear('snapshot exceeds 64 objects');
    final ids = <String>{};
    CueObject? selected;
    var rank = 0;
    for (final object in snapshot) {
      if (object.id.trim().isEmpty || !ids.add(object.id)) {
        return _clear('invalid or duplicate object ID');
      }
      final age = now - object.observedAt;
      final ttl = object.kind == CueObjectKind.target ? targetTtl : riskTtl;
      if (!object.angleDegrees.isFinite ||
          object.observedAt.isNegative ||
          age.isNegative ||
          age >= ttl) {
        continue;
      }
      final priority = _priority(object, context);
      if (priority == 0) continue;
      final candidateDistance = object.distance.index;
      final selectedDistance = selected?.distance.index ?? 99;
      // Stable tie break, independent of snapshot order: rank, distance, ID.
      if (priority > rank ||
          (priority == rank &&
              (candidateDistance < selectedDistance ||
                  (candidateDistance == selectedDistance &&
                      object.id.compareTo(selected!.id) < 0)))) {
        selected = object;
        rank = priority;
      }
    }
    if (selected == null) return _clear('no fresh relevant object');
    if (_active?.object.id != selected.id ||
        _active?.object.kind != selected.kind) {
      _tracker.reset();
    }
    final raw = DirectionPan.fromZ(
      headYaw,
      reference,
      reverse: reverse,
      objectAngle: selected.angleDegrees,
    );
    // Do not fall through to a goal when the selected hazard is behind the user.
    if (!raw.supported) return _clear('selected object outside five-way field');
    final next = CueSelection(selected, rank, _tracker.track(raw));
    final previous = _active;
    if (previous == null &&
        rank == 1 &&
        _lastStartedId == selected.id &&
        _lastStartedAt != null &&
        now - _lastStartedAt! < restartCooldown) {
      return const CueDecision(CueAction.none, null, 'target restart cooldown');
    }
    _active = next;
    if (previous == null ||
        previous.object.id != selected.id ||
        previous.object.kind != selected.kind) {
      _lastStartedId = selected.id;
      _lastStartedAt = now;
      return CueDecision(
        CueAction.play,
        next,
        previous == null ? 'selected' : 'replace active cue',
      );
    }
    return CueDecision(
      previous.sameOutput(next) ? CueAction.none : CueAction.update,
      next,
      previous.sameOutput(next)
          ? 'duplicate suppressed'
          : 'direction or priority changed',
    );
  }
}

/// A future adapter must implement stop/play/update using its own audio backend.
abstract interface class CueOutput {
  Future<void> stop();
  Future<void> play(CueSelection cue);
  Future<void> update(CueSelection cue);
}

/// Serializes output operations. New decisions invalidate queued older work.
/// A completed obsolete start is stopped before the newer cue can start.
class CueOutputDriver {
  CueOutputDriver(this.output);
  final CueOutput output;
  Future<void> _tail = Future<void>.value();
  int _revision = 0;
  bool _running = false;
  Future<void> apply(CueDecision decision) {
    if (decision.action == CueAction.none) return _tail;
    final revision = ++_revision;
    final task = _tail.then((_) async {
      if (revision != _revision) return;
      try {
        if (decision.action == CueAction.stop) {
          await output.stop();
          _running = false;
        } else if (decision.action == CueAction.play || !_running) {
          await output.stop();
          _running = false;
          if (revision != _revision) return;
          await output.play(decision.selection!);
          _running = true;
          if (revision != _revision) {
            await output.stop();
            _running = false;
          }
        } else {
          await output.update(decision.selection!);
        }
      } catch (_) {
        _running = false;
        try {
          await output.stop();
        } catch (_) {
          /* Preserve the original error. */
        }
        rethrow;
      }
    });
    // Keep the queue usable after an error while reporting this task's failure.
    _tail = task.catchError((Object _) {});
    return task;
  }
}
