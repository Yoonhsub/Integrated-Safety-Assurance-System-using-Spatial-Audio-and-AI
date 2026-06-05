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
    final distanceMeters = normalizedDistance * 20.0;

    final dx = busPosition.dx - userPosition.dx;
    final pan = (dx * 2.0).clamp(-1.0, 1.0).toDouble();

    final gain = (1.0 - (distanceMeters / 20.0)).clamp(0.15, 1.0).toDouble();

    final beepIntervalMs = (2400 - (gain * 1800)).round().clamp(600, 2400);

    return MockScenarioMetrics(
      distanceMeters: distanceMeters,
      directionLabel: directionLabelFromPan(pan),
      pan: pan,
      gain: gain,
      beepIntervalMs: beepIntervalMs,
    );
  }

  static String directionLabelFromPan(double pan) {
    if (pan <= -0.35) {
      return '왼쪽';
    }

    if (pan >= 0.35) {
      return '오른쪽';
    }

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

