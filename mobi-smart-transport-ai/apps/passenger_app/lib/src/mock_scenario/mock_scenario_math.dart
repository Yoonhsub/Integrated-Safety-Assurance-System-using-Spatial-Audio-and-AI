import 'package:flutter/material.dart';

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

class MockScenarioMath {
  const MockScenarioMath._();

  static MockScenarioMetrics calculate({
    required Offset userPosition,
    required Offset busPosition,
  }) {
    final normalizedDistance = (busPosition - userPosition).distance;
    final distanceMeters = normalizedDistance * 22.0;

    final dx = busPosition.dx - userPosition.dx;
    final dy = busPosition.dy - userPosition.dy;
    final pan = (dx * 2.2).clamp(-1.0, 1.0).toDouble();
    final closeness = (1.0 - (distanceMeters / 20.0)).clamp(0.0, 1.0);
    final verticalBoost = dy < -0.10 ? 0.08 : 0.0;
    final gain = (0.18 + (closeness * 0.78) + verticalBoost)
        .clamp(0.15, 1.0)
        .toDouble();
    final beepIntervalMs = (1400 - (gain * 950)).round().clamp(450, 1400);

    return MockScenarioMetrics(
      distanceMeters: distanceMeters,
      directionLabel: directionLabelFromPan(pan),
      pan: pan,
      gain: gain,
      beepIntervalMs: beepIntervalMs,
    );
  }

  static String directionLabelFromPan(double pan) {
    if (pan <= -0.35) return '왼쪽';
    if (pan >= 0.35) return '오른쪽';
    return '중앙';
  }

  static bool isOutsideGeofence({
    required Offset userPosition,
    required Offset stopPosition,
    required double radius,
  }) {
    return (userPosition - stopPosition).distance > radius;
  }
}
