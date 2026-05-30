// V3 Audio/Haptic Cue Service
import 'dart:async';
import 'package:flutter/services.dart';
import '../models/cue_policy.dart';

class AudioHapticCueService {
  Timer? _timer;
  CueType _currentType = CueType.none;
  int _repeatCount = 0;

  void play(CuePolicy policy) {
    if (policy.type == _currentType && _timer != null) return;
    _cancel();
    _currentType = policy.type;
    _repeatCount = 0;
    if (policy.type == CueType.none || policy.repeatCount == 0) return;
    _fire(policy);
    if (policy.interval > Duration.zero) {
      _timer = Timer.periodic(policy.interval, (_) {
        _repeatCount++;
        if (policy.repeatCount > 0 && _repeatCount >= policy.repeatCount) {
          _cancel();
          return;
        }
        _fire(policy);
      });
    }
  }

  void stop() => _cancel();

  void reset() => _cancel();

  void dispose() => _cancel();

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _currentType = CueType.none;
  }

  void _fire(CuePolicy policy) {
    switch (policy.type) {
      case CueType.targetBusNear:
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      case CueType.targetBusMid:
        HapticFeedback.mediumImpact();
        SystemSound.play(SystemSoundType.alert);
      case CueType.targetBusFar:
        HapticFeedback.lightImpact();
      case CueType.wrongBusNear:
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      case CueType.geofenceWarning:
        HapticFeedback.mediumImpact();
        SystemSound.play(SystemSoundType.alert);
      case CueType.danger:
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      case CueType.none:
        break;
    }
  }
}
