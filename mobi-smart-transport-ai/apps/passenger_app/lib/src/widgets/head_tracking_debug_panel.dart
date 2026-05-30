// V3 Head Tracking Debug Panel widget
import 'package:flutter/material.dart';
import '../models/head_tracking_state.dart';

class HeadTrackingDebugPanel extends StatelessWidget {
  final HeadTrackingState state;
  final VoidCallback? onCalibrate;

  const HeadTrackingDebugPanel({
    super.key,
    required this.state,
    this.onCalibrate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(8),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontFamily: 'monospace'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('[HEAD TRACKING]', style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold)),
            _row('Status', state.connected ? 'CONNECTED' : 'DISCONNECTED (mock)'),
            _row('Calibrated', state.calibrated.toString()),
            _row('Yaw', '${state.yaw.toStringAsFixed(1)}°'),
            _row('Pitch', '${state.pitch.toStringAsFixed(1)}°'),
            _row('Roll', '${state.roll.toStringAsFixed(1)}°'),
            _row('RelativeYaw', '${state.relativeYaw.toStringAsFixed(1)}°'),
            _row('Facing', state.facingDirection.name),
            const SizedBox(height: 4),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan[900],
                foregroundColor: Colors.white,
                textStyle: const TextStyle(fontSize: 11),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              onPressed: onCalibrate,
              child: const Text('보정 (현재 yaw를 기준으로 설정)'),
            ),
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
          SizedBox(width: 100, child: Text('$key:')),
          Expanded(child: Text(val)),
        ],
      ),
    );
  }
}
