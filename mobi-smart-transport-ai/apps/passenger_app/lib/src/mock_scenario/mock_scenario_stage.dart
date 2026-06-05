import 'package:flutter/material.dart';

import 'mock_scenario_state.dart';

class MockScenarioStage extends StatelessWidget {
  const MockScenarioStage({
    super.key,
    required this.state,
  });

  final MockScenarioState state;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'V3 Mock 시나리오 시각화 캔버스',
      hint: '사용자, 정류장, 버스, 지오펜스 상태를 시각적으로 표시합니다.',
      child: Container(
        height: 320,
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFFF2F3F5),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: const Color(0xFFD0D4DA),
          ),
        ),
 child: LayoutBuilder(
  builder: (context, constraints) {
    final canvasWidth = constraints.maxWidth;
    final canvasHeight = constraints.maxHeight;

    return Stack(
      children: [
        _GeofenceCircle(
          center: state.stopPosition,
          radius: state.geofenceRadius,
          canvasWidth: canvasWidth,
          canvasHeight: canvasHeight,
          isArmed: state.geofenceArmed,
          isReleased: state.geofenceReleased,
          isWarning: state.isUserOutsideGeofence,
        ),

_PositionedMarker(
  label: '정류장',
  icon: Icons.signpost_outlined,
  color: const Color(0xFF1565C0),
  position: state.stopPosition,
  canvasWidth: canvasWidth,
  canvasHeight: canvasHeight,
),
_PositionedMarker(
  label: '사용자',
  icon: Icons.accessibility_new,
  color: const Color(0xFF2E7D32),
  position: state.userPosition,
  canvasWidth: canvasWidth,
  canvasHeight: canvasHeight,
),
_PositionedMarker(
  label: '탑승 대상 버스',
  icon: Icons.directions_bus,
  color: const Color(0xFFFF8F00),
  position: state.targetBusPosition,
  canvasWidth: canvasWidth,
  canvasHeight: canvasHeight,
),
if (state.wrongBusPosition != null)
  _PositionedMarker(
    label: '잘못된 버스',
    icon: Icons.warning_amber_rounded,
    color: const Color(0xFFC62828),
    position: state.wrongBusPosition!,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
  ),

        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              state.currentScenarioMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  },
),
      ),
    );
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
    final shortestSide = canvasWidth < canvasHeight ? canvasWidth : canvasHeight;
    final size = shortestSide * radius * 2;
    final left = (center.dx * canvasWidth) - (size / 2);
    final top = (center.dy * canvasHeight) - (size / 2);

    Color borderColor;
    Color backgroundColor;

    if (isWarning) {
      borderColor = const Color(0xFFD32F2F);
      backgroundColor = const Color(0x22D32F2F);
    } else if (isReleased) {
      borderColor = const Color(0xFF757575);
      backgroundColor = const Color(0x11000000);
    } else if (isArmed) {
      borderColor = const Color(0xFF2E7D32);
      backgroundColor = const Color(0x222E7D32);
    } else {
      borderColor = const Color(0xFFB0BEC5);
      backgroundColor = const Color(0x11B0BEC5);
    }

    return Positioned(
      left: left,
      top: top,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: backgroundColor,
          border: Border.all(
            color: borderColor,
            width: 2,
          ),
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
  });

  final String label;
  final IconData icon;
  final Color color;
  final Offset position;
  final double canvasWidth;
  final double canvasHeight;

  static const double _markerSize = 58;

  @override
  Widget build(BuildContext context) {
    final left =
        (position.dx.clamp(0.0, 1.0) * canvasWidth) - (_markerSize / 2);
    final top =
        (position.dy.clamp(0.0, 1.0) * canvasHeight) - (_markerSize / 2);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      left: left,
      top: top,
      child: Semantics(
        label: label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _markerSize,
              height: _markerSize,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: color,
                  width: 3,
                ),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 8,
                    offset: Offset(0, 3),
                    color: Color(0x22000000),
                  ),
                ],
              ),
              child: Icon(
                icon,
                color: color,
                size: 30,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: const Color(0xFFE0E0E0),
                ),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


