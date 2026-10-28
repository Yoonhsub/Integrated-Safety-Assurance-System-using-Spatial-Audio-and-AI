import 'dart:convert';

/// Local verification contract only; not a new Backend/Safety Event schema.
enum GuidancePriority { observation }

enum TestDirection { left, center, right }

enum DirectionEvidence { explicitLocalFixture, unverified }

class DirectionalGuidance {
  const DirectionalGuidance(
      {required this.guidanceId,
      required this.sessionGeneration,
      required this.authEpoch,
      required this.priority,
      required this.text,
      required this.provenance,
      this.testDirection,
      this.directionEvidence = DirectionEvidence.unverified});
  static const syntheticProvenance = 'SYNTHETIC_DIRECTIONAL_GUIDANCE';
  final String guidanceId, sessionGeneration, text, provenance;
  final int authEpoch;
  final GuidancePriority priority;
  final TestDirection? testDirection;
  final DirectionEvidence directionEvidence;
  bool get hasReviewedDirection =>
      provenance == syntheticProvenance &&
      directionEvidence == DirectionEvidence.explicitLocalFixture &&
      testDirection != null;
  String get scopeKey => jsonEncode([authEpoch, sessionGeneration, guidanceId]);
  String get spokenText => '검증용 합성 안내입니다. $text';
  void validate() {
    if (guidanceId.isEmpty ||
        guidanceId.length > 128 ||
        sessionGeneration.isEmpty ||
        sessionGeneration.length > 128 ||
        authEpoch < 0 ||
        text.trim().isEmpty ||
        text.length > 1000 ||
        provenance.isEmpty) {
      throw ArgumentError('Invalid local Guidance contract');
    }
  }
}
