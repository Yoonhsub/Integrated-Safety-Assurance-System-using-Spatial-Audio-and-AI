import 'dart:async';
import 'package:flutter/material.dart';
import 'cue_control.dart';
import 'direction_audio_panel.dart';
import 'obstacle_cue_input.dart';

/// Local synthetic producers only. No camera, BLE scanner or server writes.
class SafetyIntegrationCheckPage extends StatefulWidget {
  const SafetyIntegrationCheckPage({super.key, this.elapsed});
  final Duration Function()? elapsed;
  @override
  State<SafetyIntegrationCheckPage> createState() =>
      _SafetyIntegrationCheckPageState();
}

class _SafetyIntegrationCheckPageState extends State<SafetyIntegrationCheckPage>
    with WidgetsBindingObserver {
  final _clock = Stopwatch()..start();
  final _epoch = DateTime.now();
  Timer? _timer;
  bool _camera = true,
      _hazard = false,
      _beaconStream = false,
      _foreground = true;
  double _angle = -90;
  DateTime? _beaconAt;
  DateTime? _oldBeaconAt;
  ObstacleCueSnapshot? _snapshot;
  Duration? _hazardAt;
  String _action = '새 비콘 수신 후 안내 소리를 시작하세요.';
  Duration get _now => widget.elapsed?.call() ?? _clock.elapsed;
  void _capture() {
    _snapshot = _camera && _foreground
        ? ObstacleCueSnapshot(
            observedAt: _now,
            observations: _hazard
                ? [
                    ObstacleCueObservation(
                        id: 'SIMULATED-risk',
                        risk: ObstacleRisk.danger,
                        roadAngleDegrees: _angle)
                  ]
                : const [],
          )
        : null;
  }

  void _change(VoidCallback action) {
    setState(() {
      action();
      _capture();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _capture();
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted || !_foreground) return;
      _change(() {
        if (_beaconStream) _beaconAt = _epoch.add(_now);
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _change(() {
      _foreground = state == AppLifecycleState.resumed;
      _beaconStream = false;
      _camera = false;
      _action = '화면 전환 후 카메라 복구·새 비콘 수신·수동 시작이 필요합니다.';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _clock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('안전 중단·재개 통합 점검')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('모의 입력 전용 · 실제 카메라/비콘/위험 판단 아님',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
          const Text('이어폰 출력은 실제입니다. 제자리에서 시험하세요. 서버와 Guidance에 전송하지 않습니다. '
              '방향·센서·RSSI도 모의값입니다. 기존 TTL과 수동 재시작 정책을 사용합니다.'),
          Text(
              '카메라: ${_camera ? "모의 프레임 수신" : "입력 상실"} · 위험: ${_hazard ? "고위험(모의)" : "해제(모의)"}'),
          Text('비콘: ${_beaconStream ? "모의 새 수신 중" : "수신 정지 / 이전 값 유지"}'),
          Text('관측 시각(ms): ${_snapshot?.observedAt.inMilliseconds ?? "없음"} · '
              '비콘 시각(ms): ${_beaconAt?.difference(_epoch).inMilliseconds ?? "없음"} · '
              '위험 시작(ms): ${_hazardAt?.inMilliseconds ?? "없음"}'),
          DropdownButton<double>(
              value: _angle,
              items: const [
                DropdownMenuItem(value: -90, child: Text('모의 왼쪽')),
                DropdownMenuItem(value: 0, child: Text('모의 중앙')),
                DropdownMenuItem(value: 90, child: Text('모의 오른쪽')),
              ],
              onChanged: (v) {
                if (v != null) _change(() => _angle = v);
              }),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: !_foreground
                    ? null
                    : () => _change(() {
                          _beaconAt = _epoch.add(_now);
                          _beaconStream = true;
                          _action = '새 비콘 수신 중. 유효 관측도 필요하며 자동 시작하지 않습니다.';
                        }),
                child: const Text('새 비콘 수신 (모의)')),
            OutlinedButton(
                onPressed: !_camera || _hazard
                    ? null
                    : () => _change(() {
                          _oldBeaconAt = _beaconAt;
                          _beaconStream = false;
                          _hazard = true;
                          _hazardAt = _now;
                          _action = '고위험 경고 선점을 확인하세요. 비콘은 이전 값으로 고정했습니다.';
                        }),
                child: const Text('고위험 발생 (모의)')),
            OutlinedButton(
                onPressed: !_hazard
                    ? null
                    : () => _change(() {
                          _hazard = false;
                          _beaconStream = false;
                          _action = '위험 해제. 과거 비콘으로 재개되면 실패입니다.';
                        }),
                child: const Text('위험 해제 (모의)')),
            OutlinedButton(
                onPressed: _oldBeaconAt == null
                    ? null
                    : () => _change(() {
                          _beaconStream = false;
                          _beaconAt = _oldBeaconAt;
                          _action = '위험 이전 비콘 시각 재사용. 시작이 차단되어야 합니다.';
                        }),
                child: const Text('과거 비콘 재사용 (모의)')),
            OutlinedButton(
                onPressed: () => _change(() {
                      _beaconStream = false;
                      _action = '비콘 새 수신 중지. 기존 TTL 만료 후 중단을 확인하세요.';
                    }),
                child: const Text('비콘 신호 상실 (모의)')),
            OutlinedButton(
                onPressed: !_camera
                    ? null
                    : () => _change(() {
                          _camera = false;
                          _beaconStream = false;
                          _action = '카메라 입력 상실. 위험 해제로 처리하면 안 됩니다.';
                        }),
                child: const Text('카메라 입력 상실 (모의)')),
            OutlinedButton(
                onPressed: _camera || !_foreground
                    ? null
                    : () => _change(() {
                          _camera = true;
                          _action = '새 카메라 관측 복구. 위험 상태는 유지하며 새 비콘도 필요합니다.';
                        }),
                child: const Text('카메라 입력 복구 (모의)')),
          ]),
          Text(_action),
          const Divider(),
          DirectionAudioPanel(
              key: const ValueKey('safety-check-output'),
              z: 0,
              reference: 0,
              fresh: _foreground,
              sensorAgeMs: 0,
              beaconRssi: _beaconAt == null ? null : -55,
              beaconSeenAt: _beaconAt,
              beaconName: '모의 목표 비콘',
              busAngle: 0,
              busEnabled: true,
              obstacles: _snapshot,
              sessionNow: () => _now,
              wallClock: () => _epoch.add(_now)),
        ]),
      );
}
