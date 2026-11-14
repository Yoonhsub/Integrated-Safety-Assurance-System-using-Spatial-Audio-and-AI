import 'package:flutter/material.dart';

import '../models/v3_guidance_models.dart';

class V3MockControlPanel extends StatelessWidget {
  const V3MockControlPanel({
    super.key,
    required this.isBusy,
    required this.onArrivedAtStop,
    required this.onLeftWaitingArea,
    required this.onDangerZone,
    required this.onReturnedToStop,
    required this.onWrongBusNear,
    required this.onTargetBusMid,
    required this.onTargetBusNear,
    required this.onNoBeacon,
    required this.onBusPassed,
    required this.onBoardingPrompt,
    required this.onBoardedSuccess,
    required this.onRepeatScript,
    required this.onRefreshArrivals,
    required this.latestBeaconDecision,
    required this.latestGeofenceMessage,
  });

  final bool isBusy;
  final VoidCallback onArrivedAtStop;
  final VoidCallback onLeftWaitingArea;
  final VoidCallback onDangerZone;
  final VoidCallback onReturnedToStop;
  final VoidCallback onWrongBusNear;
  final VoidCallback onTargetBusMid;
  final VoidCallback onTargetBusNear;
  final VoidCallback onNoBeacon;
  final VoidCallback onBusPassed;
  final VoidCallback onBoardingPrompt;
  final VoidCallback onBoardedSuccess;
  final VoidCallback onRepeatScript;
  final VoidCallback onRefreshArrivals;
  final V3BeaconDecisionResponse? latestBeaconDecision;
  final String? latestGeofenceMessage;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '시연 안내 확인',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              latestGeofenceMessage ??
                  latestBeaconDecision?.message ??
                  '모의 이벤트 주입은 자동 테스트에서 확인합니다. 실제 기기의 음성 반복과 도착정보 갱신은 여기서 확인하세요.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Deterministic mock event injection is covered by backend
                // smoke/unit tests; retain only user-facing repeat and refresh.
                _Button(
                    label: 'Repeat Line',
                    onPressed: onRepeatScript,
                    isBusy: isBusy),
                _Button(
                    label: '도착정보 갱신',
                    onPressed: onRefreshArrivals,
                    isBusy: isBusy),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.onPressed,
    required this.isBusy,
  });

  final String label;
  final VoidCallback onPressed;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: isBusy ? null : onPressed,
      child: Text(label),
    );
  }
}
