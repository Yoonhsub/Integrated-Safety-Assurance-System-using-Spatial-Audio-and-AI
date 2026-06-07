import 'package:flutter/material.dart';

import 'mock_scenario_phase.dart';
import 'mock_scenario_state.dart';

class MockScenarioMetricsPanel extends StatelessWidget {
  const MockScenarioMetricsPanel({super.key, required this.state});

  final MockScenarioState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '실시간 시나리오 수치 패널',
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.analytics_outlined, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '실시간 좌표/공간음향',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _StatusPill(
                    label: state.isPlaying ? '재생 중' : '대기',
                    color: state.isPlaying
                        ? const Color(0xFF2E7D32)
                        : colorScheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip(label: 'Phase', value: state.phase.label),
                  _MetricChip(
                    label: 'Distance',
                    value: '${state.distanceMeters.toStringAsFixed(1)} m',
                  ),
                  _MetricChip(label: 'Direction', value: state.directionLabel),
                  _MetricChip(
                    label: 'Pan',
                    value: state.pan.toStringAsFixed(2),
                  ),
                  _MetricChip(
                    label: 'Gain',
                    value: state.gain.toStringAsFixed(2),
                  ),
                  _MetricChip(
                    label: 'Interval',
                    value: '${state.beepIntervalMs} ms',
                  ),
                  _MetricChip(label: 'Cue', value: state.cueType),
                  _MetricChip(
                    label: 'Geofence',
                    value: state.isUserOutsideGeofence ? 'OUT' : 'IN',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _MetricRow(
                label: '사용자 좌표',
                value: _offsetLabel(state.userPosition),
              ),
              _MetricRow(
                label: '목표 버스 좌표',
                value: _offsetLabel(state.targetBusPosition),
              ),
              if (state.secondaryBusPosition != null)
                _MetricRow(
                  label: state.secondaryBusLabel ?? '보조 객체 좌표',
                  value: _offsetLabel(state.secondaryBusPosition!),
                ),
              _MetricRow(
                label: 'Script',
                value: state.currentScriptLineId ?? '-',
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _offsetLabel(Offset offset) {
    return 'x=${offset.dx.toStringAsFixed(2)}, y=${offset.dy.toStringAsFixed(2)}';
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text('$label: $value'),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF546E7A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF263238),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
