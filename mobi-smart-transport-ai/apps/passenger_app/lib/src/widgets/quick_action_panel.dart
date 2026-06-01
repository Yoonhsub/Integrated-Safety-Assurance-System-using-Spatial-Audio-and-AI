import 'package:flutter/material.dart';

class V3QuickActionPanel extends StatelessWidget {
  const V3QuickActionPanel({
    super.key,
    required this.isBusy,
    required this.wakeWord,
    required this.onWakeOnly,
    required this.onFindRoute,
    required this.onQueryArrival,
    required this.onSelectArrival,
    required this.onAskCanBoard,
    required this.onMissedBus,
    required this.onChangeDestination,
  });

  final bool isBusy;
  final String wakeWord;
  final VoidCallback onWakeOnly;
  final VoidCallback onFindRoute;
  final VoidCallback onQueryArrival;
  final VoidCallback onSelectArrival;
  final VoidCallback onAskCanBoard;
  final VoidCallback onMissedBus;
  final VoidCallback onChangeDestination;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quick Action Fallback',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActionChipButton(label: wakeWord, onPressed: onWakeOnly, isBusy: isBusy),
                _ActionChipButton(label: '사창사거리 안내', onPressed: onFindRoute, isBusy: isBusy),
                _ActionChipButton(label: '언제 와?', onPressed: onQueryArrival, isBusy: isBusy),
                _ActionChipButton(label: '6분 뒤 버스 선택', onPressed: onSelectArrival, isBusy: isBusy),
                _ActionChipButton(label: '지금 타도 돼?', onPressed: onAskCanBoard, isBusy: isBusy),
                _ActionChipButton(label: '나 못 탔어', onPressed: onMissedBus, isBusy: isBusy),
                _ActionChipButton(label: '충북대병원 변경', onPressed: onChangeDestination, isBusy: isBusy),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionChipButton extends StatelessWidget {
  const _ActionChipButton({
    required this.label,
    required this.onPressed,
    required this.isBusy,
  });

  final String label;
  final VoidCallback onPressed;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: isBusy ? null : onPressed,
    );
  }
}
