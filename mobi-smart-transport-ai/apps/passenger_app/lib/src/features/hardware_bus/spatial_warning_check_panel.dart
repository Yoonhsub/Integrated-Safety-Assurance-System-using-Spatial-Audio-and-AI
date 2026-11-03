import 'dart:async';
import 'package:flutter/material.dart';
import 'cue_control.dart';
import 'obstacle_cue_input.dart';
import 'direction_audio_panel.dart';

/// Explicit listening check only. Never supplies observations to real guidance.
class SpatialWarningCheckPanel extends StatefulWidget {
  const SpatialWarningCheckPanel(
      {super.key,
      required this.z,
      required this.reference,
      required this.fresh,
      required this.sensorAgeMs});
  final double? z, reference;
  final bool fresh;
  final int sensorAgeMs;
  @override
  State<SpatialWarningCheckPanel> createState() =>
      _SpatialWarningCheckPanelState();
}

class _SpatialWarningCheckPanelState extends State<SpatialWarningCheckPanel> {
  final _clock = Stopwatch()..start();
  Timer? _timer;
  double _angle = 0;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('방향 청취 확인용 입력입니다. 실제 장애물 식별 결과가 아닙니다. '
              '도로 정면 기준 방향을 선택하고 센서를 머리에 고정하세요. '
              '앞뒤 차이가 안 느껴지면 검증 완료로 판단하지 않습니다.'),
          DropdownButton<double>(
            value: _angle,
            items: const [
              DropdownMenuItem(value: 0, child: Text('정면 · 0°')),
              DropdownMenuItem(value: 180, child: Text('정후방 · 180°')),
              DropdownMenuItem(value: -90, child: Text('왼쪽 · -90°')),
              DropdownMenuItem(value: 90, child: Text('오른쪽 · +90°')),
            ],
            onChanged: (angle) {
              if (angle != null) setState(() => _angle = angle);
            },
          ),
          DirectionAudioPanel(
            z: widget.z,
            reference: widget.reference,
            fresh: widget.fresh,
            sensorAgeMs: widget.sensorAgeMs,
            busEnabled: false,
            sessionNow: () => _clock.elapsed,
            obstacles:
                ObstacleCueSnapshot(observedAt: _clock.elapsed, observations: [
              ObstacleCueObservation(
                  id: 'listening-check',
                  risk: ObstacleRisk.danger,
                  roadAngleDegrees: _angle),
            ]),
          ),
        ],
      );
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
