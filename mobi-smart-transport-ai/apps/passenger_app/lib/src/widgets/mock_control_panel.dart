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
              'Mock Control Panel',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              latestGeofenceMessage ??
                  latestBeaconDecision?.message ??
                  'mock 이벤트를 실행할 수 있어.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Button(
                  label: 'Boarding Prompt',
                  onPressed: onBoardingPrompt,
                  isBusy: isBusy,
                ),
                _Button(
                  label: 'Boarded OK',
                  onPressed: onBoardedSuccess,
                  isBusy: isBusy,
                ),
                _Button(
                  label: 'Repeat Line',
                  onPressed: onRepeatScript,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '도착',
                  onPressed: onArrivedAtStop,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '대기 범위 이탈',
                  onPressed: onLeftWaitingArea,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '위험 구역',
                  onPressed: onDangerZone,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '정류장 복귀',
                  onPressed: onReturnedToStop,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '잘못된 버스 근접',
                  onPressed: onWrongBusNear,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '타야 할 버스 중간',
                  onPressed: onTargetBusMid,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '타야 할 버스 근접',
                  onPressed: onTargetBusNear,
                  isBusy: isBusy,
                ),
                _Button(label: '비컨 없음', onPressed: onNoBeacon, isBusy: isBusy),
                _Button(
                  label: '버스 지나감',
                  onPressed: onBusPassed,
                  isBusy: isBusy,
                ),
                _Button(
                  label: '도착정보 갱신',
                  onPressed: onRefreshArrivals,
                  isBusy: isBusy,
                ),
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
