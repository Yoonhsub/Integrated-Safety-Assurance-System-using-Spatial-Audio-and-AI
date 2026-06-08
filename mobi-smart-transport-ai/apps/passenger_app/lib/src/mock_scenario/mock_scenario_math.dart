import 'dart:math' as math;

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
    final rawPan = (dx * 3.4).clamp(-1.0, 1.0).toDouble();
    final pan = _intensifyPan(rawPan);
    final closeness = (1.0 - (distanceMeters / 22.0)).clamp(0.0, 1.0);
    final verticalBoost = dy < -0.10 ? 0.10 : 0.0;
    final lateralBoost = rawPan.abs() * 0.08;
    final gain = (0.24 + (closeness * 0.76) + verticalBoost + lateralBoost)
        .clamp(0.22, 1.0)
        .toDouble();
    final beepIntervalMs = (1320 - (gain * 980)).round().clamp(320, 1320);

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

  static double _intensifyPan(double pan) {
    if (pan == 0) return 0;
    final sign = pan.isNegative ? -1.0 : 1.0;
    return sign * math.pow(pan.abs(), 0.62).toDouble();
  }

  static bool isOutsideGeofence({
    required Offset userPosition,
    required Offset stopPosition,
    required double radius,
  }) {
    return (userPosition - stopPosition).distance > radius;
  }
}
