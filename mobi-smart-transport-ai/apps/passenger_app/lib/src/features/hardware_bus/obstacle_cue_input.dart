import 'cue_control.dart';

/// Local audio input, not a Vision detector or a shared backend contract.
/// The producer supplies risk and a direction in the road-calibrated frame:
/// zero = road front, positive = right. Camera-relative angles require conversion
/// using head pose AT CAPTURE, not the latest pose. Unknown directions must not
/// be replaced with zero. No input means no obstacle cue.
class ObstacleCueObservation {
  const ObstacleCueObservation({
    required this.id,
    required this.risk,
    required this.roadAngleDegrees,
  });
  final String id;
  final ObstacleRisk risk;
  final double roadAngleDegrees;
}

/// Complete replacement snapshot: omission clears an object; never an event queue.
/// observedAt and controller now must share the SAME monotonic session clock.
/// Retain the capture timestamp across ticks; do not refresh it on receipt/playback.
/// A producer must discard older frames and clear its snapshot on session reset.
class ObstacleCueSnapshot {
  ObstacleCueSnapshot(
      {required this.observedAt,
      required Iterable<ObstacleCueObservation> observations})
      : observations = List.unmodifiable(observations.take(65));
  final Duration observedAt;
  final List<ObstacleCueObservation> observations;

  List<CueObject> toCueObjects() {
    if (observedAt.isNegative || observations.length > 64) {
      throw ArgumentError(
          'Nonnegative capture time and at most 64 obstacles required');
    }
    final ids = <String>{};
    return observations.map((observation) {
      final id = observation.id.trim();
      if (id.isEmpty ||
          !ids.add(id) ||
          !observation.roadAngleDegrees.isFinite ||
          observation.roadAngleDegrees.abs() > 180) {
        throw ArgumentError(
            'Unique obstacle IDs and known angles within [-180, 180] required');
      }
      return CueObject(
        id: 'obstacle:$id',
        kind: CueObjectKind.obstacle,
        // Not a distance estimate. Explicit risk overrides the legacy distance policy.
        distance: CueDistance.medium,
        obstacleRisk: observation.risk,
        angleDegrees: observation.roadAngleDegrees,
        observedAt: observedAt,
      );
    }).toList(growable: false);
  }
}
