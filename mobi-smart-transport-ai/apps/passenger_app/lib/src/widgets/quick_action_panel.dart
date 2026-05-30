// V3 Quick Action Panel widget
import 'package:flutter/material.dart';

typedef QuickAction = Future<void> Function(String utterance);

class QuickActionPanel extends StatelessWidget {
  final QuickAction onUtterance;
  final VoidCallback? onReset;

  const QuickActionPanel({
    super.key,
    required this.onUtterance,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _btn('사창사거리 가기', '자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?'),
        _btn('502번 언제 와?', '자비스, 그 버스 언제 와?'),
        _btn('6분 뒤 버스로', '응, 6분 뒤 오는 걸로 안내해줘.'),
        _btn('탑승 가능?', '자비스, 지금 앞에 온 버스 타도 돼?'),
        _btn('탑승했어', '자비스, 탔어.'),
        _btn('못 탔어', '자비스, 나 못 탔어.'),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red[800],
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontSize: 11),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          onPressed: onReset,
          child: const Text('리셋'),
        ),
      ],
    );
  }

  Widget _btn(String label, String utterance) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.indigo[700],
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 11),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      onPressed: () => onUtterance(utterance),
      child: Text(label),
    );
  }
}
