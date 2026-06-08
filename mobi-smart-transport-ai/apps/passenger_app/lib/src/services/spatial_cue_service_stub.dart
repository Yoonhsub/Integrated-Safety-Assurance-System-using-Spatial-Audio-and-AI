import 'package:flutter/services.dart';

class SpatialCueService {
  Future<void> prepare() async {}

  Future<void> startCue({
    required double pan,
    required double gain,
    required int intervalMs,
    required String pattern,
  }) async {}

  Future<void> updateCue({
    required double pan,
    required double gain,
    required int intervalMs,
    required String pattern,
  }) async {}

  Future<void> stopCue() async {}

  Future<void> playAlarm({String pattern = 'alarm'}) async {
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      await SystemSound.play(SystemSoundType.click);
    }
  }

  Future<bool> playClip(String url, {double pan = 0, double gain = 1}) async =>
      false;

  Future<void> updateClipSpatial({
    required double pan,
    required double gain,
  }) async {}

  Future<void> stopClip() async {}

  Future<void> dispose() async {
    await stopCue();
    await stopClip();
  }
}
