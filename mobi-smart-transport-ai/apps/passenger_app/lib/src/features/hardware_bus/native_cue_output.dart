import 'package:flutter/services.dart';
import 'cue_control.dart';

class ToneInput {
  const ToneInput(this.sensorAgeMs, this.beaconAgeMs, this.targetIntervalMs);
  final int sensorAgeMs, beaconAgeMs, targetIntervalMs;
}

/// Existing Android tone channel adapter. Repeated updates refresh its watchdog.
class NativeCueOutput implements CueOutput {
  NativeCueOutput(this.input);
  static const channel = MethodChannel('mobi.passenger/hardware-tone');
  final ToneInput Function() input;
  String route = '', reason = '';
  bool running = false;

  Future<void> _send(String method, CueSelection cue) async {
    final state = input();
    final warning = cue.object.kind == CueObjectKind.obstacle;
    final result = await channel.invokeMapMethod<String, dynamic>(method, {
      'left': cue.direction.left,
      'right': cue.direction.right,
      'sensorAgeMs': state.sensorAgeMs,
      'beaconAgeMs': state.beaconAgeMs,
      'intervalMs':
          warning ? cue.repeatInterval.inMilliseconds : state.targetIntervalMs,
      'pattern': warning ? 'warning' : 'target',
    });
    running = result?['running'] == true;
    route = result?['route'] as String? ?? '';
    reason = result?['reason'] as String? ?? '오디오 출력이 중지됐습니다.';
    if (!running) throw StateError(reason);
  }

  @override
  Future<void> play(CueSelection cue) => _send('start', cue);
  @override
  Future<void> update(CueSelection cue) => _send('update', cue);
  @override
  Future<void> stop() async {
    running = false;
    await channel.invokeMethod<void>('stop');
  }
}
