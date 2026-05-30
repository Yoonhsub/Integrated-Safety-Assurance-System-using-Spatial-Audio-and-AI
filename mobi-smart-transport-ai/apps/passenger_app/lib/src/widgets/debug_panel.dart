// V3 Debug Panel widget
import 'package:flutter/material.dart';
import '../models/v3_guidance_models.dart';

class DebugPanel extends StatelessWidget {
  final GuidanceSession? session;
  final String? geofenceStatus;
  final String? lastApi;
  final String? nearestBeaconId;
  final String? nearestRouteNo;
  final String? decision;

  const DebugPanel({
    super.key,
    this.session,
    this.geofenceStatus,
    this.lastApi,
    this.nearestBeaconId,
    this.nearestRouteNo,
    this.decision,
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(8),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('[DEBUG PANEL]', style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold)),
            _row('currentState', s?.guidanceState.name ?? '-'),
            _row('destination', s?.destination ?? '-'),
            _row('selectedStopName', s?.selectedStopName ?? '-'),
            _row('selectedRouteNo', s?.selectedRouteNo ?? '-'),
            _row('targetBusId', s?.targetBusId ?? '-'),
            _row('targetArrivalMinutes', s?.targetArrivalMinutes?.toString() ?? '-'),
            _row('nearestBeaconId', nearestBeaconId ?? s?.nearestBeaconId ?? '-'),
            _row('nearestRouteNo', nearestRouteNo ?? s?.nearestRouteNo ?? '-'),
            _row('geofenceStatus', geofenceStatus ?? '-'),
            _row('hasArrivedAtStop', s?.hasArrivedAtStop.toString() ?? '-'),
            _row('geofenceArmed', s?.geofenceArmed.toString() ?? '-'),
            _row('lastAiIntent', s?.lastAiIntent ?? '-'),
            _row('lastApi', lastApi ?? '-'),
            _row('lastDecision', decision ?? s?.lastDecision ?? '-'),
            _row('fallbackSource', s?.fallbackSource ?? '-'),
          ],
        ),
      ),
    );
  }

  Widget _row(String key, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(width: 160, child: Text('$key:')),
          Expanded(child: Text(val, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}
