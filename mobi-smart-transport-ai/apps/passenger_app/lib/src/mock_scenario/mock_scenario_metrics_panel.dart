import 'package:flutter/material.dart';

import 'mock_scenario_state.dart';

class MockScenarioMetricsPanel extends StatelessWidget {
  const MockScenarioMetricsPanel({
    super.key,
    required this.state,
  });

  final MockScenarioState state;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'V3 Mock 시나리오 수치 패널',
      hint: '현재 시나리오 단계와 공간음향 파라미터를 표시합니다.',
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(
            color: Color(0xFFE0E0E0),
          ),
        ),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '실시간 시나리오 수치',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 12),
              _MetricRow(
                label: 'Status',
                value: 'Mock scenario metrics ready',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 5,
      ),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF546E7A),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF263238),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
