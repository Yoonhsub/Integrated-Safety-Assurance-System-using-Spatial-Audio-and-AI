// V3 Mock Control Panel widget
import 'package:flutter/material.dart';

typedef MockAction = Future<void> Function(String action);

class MockControlPanel extends StatelessWidget {
  final MockAction onAction;

  const MockControlPanel({super.key, required this.onAction});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _btn('정류장 범위 진입', 'ARRIVED_AT_STOP'),
        _btn('정류장 범위 이탈', 'LEFT_WAITING_AREA'),
        _btn('위험구역 진입', 'DANGER_ZONE'),
        _btn('정류장 복귀', 'RETURNED_TO_STOP'),
        _btn('BUS_1 접근', 'BUS1_NEAR'),
        _btn('BUS_2 접근', 'BUS2_NEAR'),
        _btn('BUS_2 멀어짐', 'BUS2_FAR'),
        _btn('버스 통과', 'BUS_PASSED'),
        _btn('API 실패', 'API_FAIL'),
        _btn('STT 실패', 'STT_FAIL'),
        _btn('탑승 성공', 'BOARDED'),
        _btn('탑승 실패', 'MISSED'),
      ],
    );
  }

  Widget _btn(String label, String action) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blueGrey[800],
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 11),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      onPressed: () => onAction(action),
      child: Text(label),
    );
  }
}
