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
        child: Center(
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
    );
  }
}

