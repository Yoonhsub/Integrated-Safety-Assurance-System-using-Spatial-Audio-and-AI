import 'package:flutter/material.dart';

import '../models/v3_guidance_models.dart';

class V3DebugPanel extends StatelessWidget {
  const V3DebugPanel({
    super.key,
    required this.baseUrl,
    required this.healthMessage,
    required this.sessionState,
    required this.lastAgentResponse,
    required this.lastArrivals,
    required this.lastBeaconDecision,
    required this.latestBeacon,
    required this.latestBeaconError,
    required this.headTracking,
    required this.activeCueType,
  });

  final String baseUrl;
  final String healthMessage;
  final V3GuidanceState? sessionState;
  final V3AgentResponse? lastAgentResponse;
  final V3BusArrivalsResponse? lastArrivals;
  final V3BeaconDecisionResponse? lastBeaconDecision;
  final V3BeaconLatestResponse? latestBeacon;
  final String? latestBeaconError;
  final HeadTrackingDebugSnapshot headTracking;
  final String? activeCueType;

  @override
  Widget build(BuildContext context) {
    final state = sessionState;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Debug Panel',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            _DebugRow(label: 'API base', value: baseUrl),
            _DebugRow(label: 'health', value: healthMessage),
            _DebugRow(label: 'sessionId', value: state?.sessionId ?? '-'),
            _DebugRow(label: 'state', value: state?.state ?? '-'),
            _DebugRow(label: 'wakeWord', value: state?.wakeWord ?? '-'),
            _DebugRow(label: 'destination', value: state?.selectedDestination ?? '-'),
            _DebugRow(label: 'routeNo', value: state?.selectedRouteNo ?? '-'),
            _DebugRow(label: 'stopId', value: state?.selectedStopId ?? '-'),
            _DebugRow(label: 'targetBusId', value: state?.targetBusId ?? '-'),
            _DebugRow(label: 'geofenceArmed', value: '${state?.geofenceArmed ?? false}'),
            _DebugRow(label: 'lastDecision', value: state?.lastDecision ?? '-'),
            _DebugRow(label: 'nearestBeacon', value: _mapSummary(state?.nearestBeacon)),
            _DebugRow(label: 'targetBus', value: _mapSummary(state?.targetBus)),
            _DebugRow(label: 'agentIntent', value: lastAgentResponse?.intent ?? '-'),
            _DebugRow(label: 'agentTtsMode', value: lastAgentResponse?.ttsMode ?? '-'),
            _DebugRow(label: 'agentFallback', value: lastAgentResponse?.fallbackSource ?? '-'),
            _DebugRow(label: 'arrivalsFallback', value: lastArrivals?.fallbackSource ?? '-'),
            _DebugRow(label: 'arrivalsCount', value: '${lastArrivals?.arrivals.length ?? 0}'),
            _DebugRow(label: 'beaconDecision', value: lastBeaconDecision?.decision ?? '-'),
            _DebugRow(label: 'beaconLatestStatus', value: latestBeacon?.status ?? '-'),
            _DebugRow(label: 'beaconLatestMessage', value: latestBeacon?.message ?? '-'),
            _DebugRow(label: 'beaconLatestBeaconId', value: latestBeacon?.beaconId ?? '-'),
            _DebugRow(label: 'beaconLatestBusId', value: latestBeacon?.busId ?? '-'),
            _DebugRow(label: 'beaconLatestCueType', value: latestBeacon?.cueType ?? latestBeacon?.cue.type ?? '-'),
            _DebugRow(
              label: 'beaconLatestDistance',
              value: latestBeacon?.distanceMeters == null
                  ? '-'
                  : '${latestBeacon!.distanceMeters!.toStringAsFixed(1)}m',
            ),
            _DebugRow(
              label: 'beaconLatestPanGain',
              value: latestBeacon == null
                  ? '-'
                  : 'pan=${latestBeacon!.pan?.toStringAsFixed(2) ?? '-'} · gain=${latestBeacon!.gain?.toStringAsFixed(2) ?? '-'}',
            ),
            _DebugRow(
              label: 'beaconLatestInterval',
              value: latestBeacon?.intervalMs == null ? '-' : '${latestBeacon!.intervalMs}ms',
            ),
            _DebugRow(
              label: 'beaconLatestFlags',
              value: latestBeacon == null
                  ? '-'
                  : 'speak=${latestBeacon!.shouldSpeak} · beep=${latestBeacon!.cue.shouldBeep} · spatial=${latestBeacon!.shouldPlaySpatialCue}',
            ),
            _DebugRow(label: 'beaconLatestError', value: latestBeaconError ?? '-'),
            _DebugRow(label: 'activeCue', value: activeCueType ?? '-'),
            const Divider(height: 24),
            Text(
              'Head Tracking Debug',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            _DebugRow(label: 'status', value: headTracking.statusLabel),
            _DebugRow(label: 'yaw', value: _angle(headTracking.yaw)),
            _DebugRow(label: 'pitch', value: _angle(headTracking.pitch)),
            _DebugRow(label: 'roll', value: _angle(headTracking.roll)),
            Text(
              '헤드트래킹은 현재 debug 표시만 담당하고, 탑승 가능 판단은 백엔드 비컨/rule engine이 담당합니다.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _mapSummary(Map<String, dynamic>? value) {
    if (value == null || value.isEmpty) return '-';
    final busId = value['busId']?.toString();
    final routeNo = value['routeNo']?.toString();
    final distance = value['distanceMeters']?.toString();
    final rssi = value['rssi']?.toString();
    return [
      if (busId != null) busId,
      if (routeNo != null) 'route=$routeNo',
      if (distance != null) 'm=$distance',
      if (rssi != null) 'rssi=$rssi',
    ].join(' · ');
  }

  String _angle(double? value) => value == null ? '-' : '${value.toStringAsFixed(1)}°';
}

class _DebugRow extends StatelessWidget {
  const _DebugRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
