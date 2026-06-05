class MockScenarioMetrics {
  const MockScenarioMetrics({
    required this.distanceMeters,
    required this.directionLabel,
    required this.pan,
    required this.gain,
    required this.beepIntervalMs,
  });

  final double distanceMeters;
  final String directionLabel;
  final double pan;
  final double gain;
  final int beepIntervalMs;
}

