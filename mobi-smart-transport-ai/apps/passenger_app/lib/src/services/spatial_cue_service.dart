import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

/// 공간음향 beep 큐. iOS(Chrome 포함)에서 직접 만든 Web Audio 컨텍스트가 소리를 내지
/// 못하는 문제 때문에, 검증된 audioplayers 경로로 짧은 beep mp3를 주기 재생한다.
/// 좌우 방향은 setBalance(pan), 거리감은 setVolume(gain), 간격은 타이머로 표현한다.
class SpatialCueService {
  SpatialCueService({AudioPlayer? player})
      : _player = player ?? AudioPlayer(playerId: 'mobi-spatial-beep');

  final AudioPlayer _player;
  Timer? _timer;
  double _pan = 0.0;
  double _gain = 0.5;
  int _intervalMs = 800;
  String _pattern = 'normal';
  String? _loadedAsset;
  bool _started = false;

  String _assetForPattern(String pattern) {
    if (pattern == 'alarm' || pattern == 'missed' || pattern == 'warning') {
      return 'mock_voice/beep_alarm.mp3';
    }
    return 'mock_voice/beep.mp3';
  }

  Future<void> prepare() async {
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
    } catch (_) {}
  }

  Future<void> _ensureAsset(String pattern) async {
    final asset = _assetForPattern(pattern);
    if (_loadedAsset == asset) return;
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSource(AssetSource(asset));
      _loadedAsset = asset;
    } catch (_) {}
  }

  Future<void> _fire() async {
    try {
      await _player.setBalance(_pan.clamp(-1.0, 1.0));
      await _player.setVolume(_gain.clamp(0.0, 1.0));
      await _player.seek(Duration.zero);
      await _player.resume();
    } catch (_) {}
  }

  void _restartTimer() {
    _timer?.cancel();
    final ms = _intervalMs.clamp(250, 3000);
    _timer = Timer.periodic(Duration(milliseconds: ms), (_) => _fire());
  }

  Future<void> startCue({
    required double pan,
    required double gain,
    required int intervalMs,
    required String pattern,
  }) async {
    _pan = pan;
    _gain = gain;
    _intervalMs = intervalMs;
    _pattern = pattern;
    await _ensureAsset(pattern);
    _started = true;
    await _fire();
    _restartTimer();
  }

  Future<void> updateCue({
    required double pan,
    required double gain,
    required int intervalMs,
    required String pattern,
  }) async {
    if (!_started) {
      await startCue(
          pan: pan, gain: gain, intervalMs: intervalMs, pattern: pattern);
      return;
    }
    final patternChanged = pattern != _pattern;
    final intervalChanged = intervalMs != _intervalMs;
    _pan = pan;
    _gain = gain;
    _intervalMs = intervalMs;
    _pattern = pattern;
    if (patternChanged) {
      await _ensureAsset(pattern);
    }
    if (intervalChanged) {
      _restartTimer();
    }
  }

  Future<void> stopCue() async {
    _timer?.cancel();
    _timer = null;
    _started = false;
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> playAlarm({String pattern = 'alarm'}) async {
    await startCue(
      pan: 0.0,
      gain: 0.9,
      intervalMs: pattern == 'missed' ? 900 : 420,
      pattern: pattern,
    );
  }

  Future<void> dispose() async {
    await stopCue();
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
