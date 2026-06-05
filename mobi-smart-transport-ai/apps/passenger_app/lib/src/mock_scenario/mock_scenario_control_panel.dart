import 'package:flutter/material.dart';

import 'mock_scenario_controller.dart';

class MockScenarioControlPanel extends StatelessWidget {
  const MockScenarioControlPanel({
    super.key,
    required this.controller,
  });

  final MockScenarioController controller;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'V3 Mock 시나리오 제어 패널',
      hint: '버스 탑승 시나리오를 단계별로 실행하는 버튼 모음입니다.',
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(
            color: Color(0xFFE0E0E0),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ScenarioButton(
                label: '초기화',
                icon: Icons.restart_alt,
                onPressed: controller.reset,
              ),
              _ScenarioButton(
                label: '정류장 도착',
                icon: Icons.place_outlined,
                onPressed: controller.arriveAtStop,
              ),
              _ScenarioButton(
                label: '버스 접근',
                icon: Icons.directions_bus_outlined,
                onPressed: controller.startTargetBusApproach,
              ),
              _ScenarioButton(
                label: '버스 이동',
                icon: Icons.compare_arrows,
                onPressed: controller.moveBusLeftToRight,
              ),
              _ScenarioButton(
                label: '버스 정차',
                icon: Icons.stop_circle_outlined,
                onPressed: controller.stopBus,
              ),
              _ScenarioButton(
                label: '버스로 접근',
                icon: Icons.directions_walk,
                onPressed: controller.userApproachesBus,
              ),
              _ScenarioButton(
                label: '탑승 안내',
                icon: Icons.record_voice_over_outlined,
                onPressed: controller.showBoardingPrompt,
              ),
              _ScenarioButton(
                label: '탑승 성공',
                icon: Icons.check_circle_outline,
                onPressed: controller.confirmBoarded,
              ),
              _ScenarioButton(
                label: '지오펜스 이탈',
                icon: Icons.warning_amber_rounded,
                onPressed: controller.userLeavesGeofence,
              ),
              _ScenarioButton(
                label: '지오펜스 복귀',
                icon: Icons.keyboard_return,
                onPressed: controller.userReturnsToGeofence,
              ),
              _ScenarioButton(
                label: '잘못된 버스',
                icon: Icons.report_problem_outlined,
                onPressed: controller.wrongBusApproaches,
              ),
              _ScenarioButton(
                label: '버스 놓침',
                icon: Icons.cancel_outlined,
                onPressed: controller.confirmMissedBus,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScenarioButton extends StatelessWidget {
  const _ScenarioButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
