import 'package:flutter/material.dart';

import 'mock_scenario_phase.dart';
import 'mock_scenario_state.dart';

class MockScenarioStage extends StatelessWidget {
  const MockScenarioStage({super.key, required this.state});

  final MockScenarioState state;

  @override
  Widget build(BuildContext context) {
    final isWarning =
        state.phase == MockScenarioPhase.geofenceWarning ||
        state.phase == MockScenarioPhase.wrongBusWarning ||
        state.phase == MockScenarioPhase.dangerWarning ||
        state.phase == MockScenarioPhase.missedBus ||
        state.phase == MockScenarioPhase.signalLost ||
        state.isUserOutsideGeofence;
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: '시나리오 시뮬레이션 무대',
      liveRegion: true,
      child: Container(
        height: 380,
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isWarning ? colorScheme.error : colorScheme.outlineVariant,
            width: isWarning ? 2.5 : 1,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasWidth = constraints.maxWidth;
            final canvasHeight = constraints.maxHeight;

            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ScenarioStagePainter(
                      isWarning: isWarning,
                      colorScheme: colorScheme,
                    ),
                  ),
                ),
                _GeofenceCircle(
                  center: state.stopPosition,
                  radius: state.geofenceRadius,
                  canvasWidth: canvasWidth,
                  canvasHeight: canvasHeight,
                  isArmed: state.geofenceArmed,
                  isReleased: state.geofenceReleased,
                  isWarning:
                      state.phase == MockScenarioPhase.geofenceWarning ||
                      state.isUserOutsideGeofence,
                ),
                _PositionedMarker(
                  label: '정류장',
                  icon: Icons.signpost_outlined,
                  color: colorScheme.primary,
                  position: state.stopPosition,
                  canvasWidth: canvasWidth,
                  canvasHeight: canvasHeight,
                  compact: true,
                ),
                _PositionedMarker(
                  label: state.targetBusLabel,
                  icon: state.busStopped
                      ? Icons.directions_bus_filled
                      : Icons.directions_bus_outlined,
                  color: const Color(0xFFFF8F00),
                  position: state.targetBusPosition,
                  canvasWidth: canvasWidth,
                  canvasHeight: canvasHeight,
                ),
                if (state.secondaryBusPosition != null)
                  _PositionedMarker(
                    label: state.secondaryBusLabel ?? '보조 객체',
                    icon: _secondaryIcon(state.secondaryBusLabel),
                    color: state.phase == MockScenarioPhase.wrongBusWarning
                        ? colorScheme.error
                        : const Color(0xFF6D4C41),
                    position: state.secondaryBusPosition!,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    compact: true,
                  ),
                _PositionedMarker(
                  label: '사용자',
                  icon: Icons.accessibility_new,
                  color: const Color(0xFF2E7D32),
                  position: state.userPosition,
                  canvasWidth: canvasWidth,
                  canvasHeight: canvasHeight,
                ),
                Positioned(
                  left: 14,
                  top: 14,
                  right: 14,
                  child: _ScenarioMessageBanner(
                    phaseLabel: state.phase.label,
                    message: state.currentScenarioMessage,
                    isWarning: isWarning,
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 14,
                  child: _AudioVectorBar(state: state),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  IconData _secondaryIcon(String? label) {
    final text = label ?? '';
    if (text.contains('혼잡')) return Icons.groups_2_outlined;
    if (text.contains('뒷문')) return Icons.door_sliding_outlined;
    if (text.contains('잘못') || text.contains('다른')) {
      return Icons.report_problem_outlined;
    }
    return Icons.directions_bus_outlined;
  }
}

class _ScenarioStagePainter extends CustomPainter {
  const _ScenarioStagePainter({
    required this.isWarning,
    required this.colorScheme,
  });

  final bool isWarning;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    final roadPaint = Paint()..color = const Color(0xFF4A4F55);
    final busLanePaint = Paint()..color = const Color(0xFF626970);
    final sidewalkPaint = Paint()..color = const Color(0xFFE8ECEF);
    final curbPaint = Paint()
      ..color = const Color(0xFFFFC400)
      ..strokeWidth = 4;
    final dashedPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.72)
      ..strokeWidth = 2;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.56),
      roadPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.24, size.width, size.height * 0.16),
      busLanePaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.56, size.width, size.height * 0.44),
      sidewalkPaint,
    );
    canvas.drawLine(
      Offset(0, size.height * 0.56),
      Offset(size.width, size.height * 0.56),
      curbPaint,
    );

    for (var x = 18.0; x < size.width; x += 48) {
      canvas.drawLine(
        Offset(x, size.height * 0.16),
        Offset(x + 24, size.height * 0.16),
        dashedPaint,
      );
    }

    final shelterPaint = Paint()
      ..color = colorScheme.primaryContainer.withValues(alpha: 0.75);
    final shelterRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.40,
        size.height * 0.58,
        size.width * 0.20,
        size.height * 0.16,
      ),
      const Radius.circular(8),
    );
    canvas.drawRRect(shelterRect, shelterPaint);

    if (isWarning) {
      final warningPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colorScheme.error.withValues(alpha: 0.65);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        warningPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScenarioStagePainter oldDelegate) {
    return oldDelegate.isWarning != isWarning ||
        oldDelegate.colorScheme != colorScheme;
  }
}

class _GeofenceCircle extends StatelessWidget {
  const _GeofenceCircle({
    required this.center,
    required this.radius,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.isArmed,
    required this.isReleased,
    required this.isWarning,
  });

  final Offset center;
  final double radius;
  final double canvasWidth;
  final double canvasHeight;
  final bool isArmed;
  final bool isReleased;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final shortestSide = canvasWidth < canvasHeight
        ? canvasWidth
        : canvasHeight;
    final size = shortestSide * radius * 2;
    final left = (center.dx * canvasWidth) - (size / 2);
    final top = (center.dy * canvasHeight) - (size / 2);

    Color borderColor;
    Color backgroundColor;
    if (isWarning) {
      borderColor = Theme.of(context).colorScheme.error;
      backgroundColor = Theme.of(
        context,
      ).colorScheme.error.withValues(alpha: 0.14);
    } else if (isReleased) {
      borderColor = const Color(0xFF757575);
      backgroundColor = const Color(0x22000000);
    } else if (isArmed) {
      borderColor = const Color(0xFF2E7D32);
      backgroundColor = const Color(0x332E7D32);
    } else {
      borderColor = const Color(0xFFB0BEC5);
      backgroundColor = const Color(0x22B0BEC5);
    }

    return Positioned(
      left: left,
      top: top,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: backgroundColor,
          border: Border.all(color: borderColor, width: 2),
        ),
      ),
    );
  }
}

class _PositionedMarker extends StatelessWidget {
  const _PositionedMarker({
    required this.label,
    required this.icon,
    required this.color,
    required this.position,
    required this.canvasWidth,
    required this.canvasHeight,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Offset position;
  final double canvasWidth;
  final double canvasHeight;
  final bool compact;

  static const double _markerSize = 54;

  @override
  Widget build(BuildContext context) {
    final left =
        (position.dx.clamp(0.02, 0.98) * canvasWidth) - (_markerSize / 2);
    final top =
        (position.dy.clamp(0.06, 0.94) * canvasHeight) - (_markerSize / 2);

    return Positioned(
      left: left,
      top: top,
      child: Semantics(
        label: label,
        child: SizedBox(
          width: compact ? 80 : 104,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 3),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 8,
                      offset: Offset(0, 3),
                      color: Color(0x26000000),
                    ),
                  ],
                ),
                child: SizedBox(
                  width: _markerSize,
                  height: _markerSize,
                  child: Icon(icon, color: color, size: compact ? 26 : 30),
                ),
              ),
              const SizedBox(height: 4),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE0E0E0)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 10 : 11,
                      height: 1.1,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScenarioMessageBanner extends StatelessWidget {
  const _ScenarioMessageBanner({
    required this.phaseLabel,
    required this.message,
    required this.isWarning,
  });

  final String phaseLabel;
  final String message;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isWarning
            ? colorScheme.errorContainer.withValues(alpha: 0.96)
            : colorScheme.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isWarning ? colorScheme.error : colorScheme.outlineVariant,
        ),
        boxShadow: const [
          BoxShadow(
            blurRadius: 10,
            offset: Offset(0, 4),
            color: Color(0x18000000),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isWarning ? Icons.warning_amber_rounded : Icons.assistant,
              color: isWarning
                  ? colorScheme.onErrorContainer
                  : colorScheme.primary,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    phaseLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: isWarning
                          ? colorScheme.onErrorContainer
                          : colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: isWarning
                          ? colorScheme.onErrorContainer
                          : colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioVectorBar extends StatelessWidget {
  const _AudioVectorBar({required this.state});

  final MockScenarioState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final alignment = Alignment(state.pan.clamp(-1.0, 1.0), 0);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.spatial_audio_off_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '공간음향 ${state.directionLabel} · ${state.distanceMeters.toStringAsFixed(1)}m',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${state.beepIntervalMs}ms',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 8,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Align(
                alignment: alignment,
                child: FractionallySizedBox(
                  widthFactor: (0.12 + state.gain * 0.18).clamp(0.12, 0.30),
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _cueColor(state.cueType, colorScheme),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _cueColor(String cueType, ColorScheme colorScheme) {
    return switch (cueType) {
      'alarm' || 'missed' => colorScheme.error,
      'warning' => const Color(0xFFFFA000),
      'success' => const Color(0xFF2E7D32),
      _ => colorScheme.primary,
    };
  }
}
