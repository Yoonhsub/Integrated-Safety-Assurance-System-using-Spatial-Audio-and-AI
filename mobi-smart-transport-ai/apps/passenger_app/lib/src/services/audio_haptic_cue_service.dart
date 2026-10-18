import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/v3_guidance_models.dart';
import 'live_audio_player.dart';
import 'speech_priority_coordinator.dart';
import 'audio_shutdown.dart';

abstract interface class CueFeedback {
  Future<void> vibrate({required bool heavy});
  Future<void> beep();
}

class PlatformCueFeedback implements CueFeedback {
  @override
  Future<void> vibrate({required bool heavy}) =>
      heavy ? HapticFeedback.heavyImpact() : HapticFeedback.mediumImpact();
  @override
  Future<void> beep() => SystemSound.play(SystemSoundType.click);
}

class AudioHapticCueService {
  AudioHapticCueService(
      {FlutterTts? flutterTts,
      AudioPlayer? audioPlayer,
      LiveAudioPlayer? liveAudioPlayer,
      SpeechPriorityCoordinator? speechPriority,
      CueFeedback? feedback,
      this.onAudioError})
      : _priority = speechPriority ??
            (flutterTts == null
                ? sharedSpeechPriority
                : SpeechPriorityCoordinator(FlutterSpeechEngine(flutterTts))),
        _feedback = feedback ?? PlatformCueFeedback(),
        _audioPlayer = audioPlayer ?? AudioPlayer(),
        _liveAudioPlayer = liveAudioPlayer ?? LiveAudioPlayer();
  final SpeechPriorityCoordinator _priority;
  final Object _voiceOwner = Object();
  final AudioPlayer _audioPlayer;
  final LiveAudioPlayer _liveAudioPlayer;
  final CueFeedback _feedback;
  final void Function(String message)? onAudioError;
  String? warningError, speechError;
  Future<void>? _vibrationPending, _beepPending;
  bool _disposed = false;
  Timer? _cueTimer;
  String? _activeCueType;
  PriorityLease? _held;
  PriorityLease? _playbackLease;
  StreamSubscription<void>? _complete;
  int _generation = 0, _cueGeneration = 0;
  PriorityLease? _quarantine;
  final Set<PriorityLease> _retiring = {};
  Future<void>? _playerStarting;
  late final _shutdown = AudioShutdown(onHold: () {
    _quarantine ??= _priority.claimPriority();
  }, onConfirmed: () {
    for (final lease in _retiring) {
      lease.release();
    }
    _retiring.clear();
    _quarantine?.release();
    _quarantine = null;
  });
  bool get shutdownConfirmed => _shutdown.confirmed;

  Future<void> _stopPlayer() async {
    final starting = _playerStarting;
    await _audioPlayer.stop();
    // A late native play may outlive stop's method response.
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
      await _audioPlayer.stop();
    }
  }

  Future<void> _stopVoiceOutputs() async {
    final playback = _playbackLease, complete = _complete;
    if (playback != null) _retiring.add(playback);
    _playbackLease = null;
    _complete = null;
    // Listener cancellation is not proof of output shutdown. Generation checks
    // already retire its callbacks; observe cleanup independently.
    unawaited(Future<void>.sync(() async {
      await complete?.cancel();
    }).catchError((Object _) {
      _report('오디오 완료 구독 정리에 실패했습니다.');
    }));
    try {
      await _shutdown.run([
        () => _priority.stopPriority(_voiceOwner),
        _stopPlayer,
        _liveAudioPlayer.stop,
      ]);
    } on AudioShutdownFailure catch (error) {
      speechError = error.toString();
      _report(speechError!);
      rethrow;
    }
  }

  String? get activeCueType => _activeCueType;
  bool get isLooping => _cueTimer?.isActive ?? false;

  Future<void> playCue(V3Cue cue,
      {String? fallbackMessage,
      bool speakMessage = true,
      bool systemBeep = true}) async {
    if (_disposed) return;
    if (cue.isNone) {
      await stopCue();
      return;
    }
    final cueType = cue.type;
    final message = cue.message ?? fallbackMessage ?? _defaultMessage(cueType);
    if (_activeCueType == cueType && isLooping) return;
    final stopping = stopCue(); // Invalidates the previous generation now.
    final generation = _generation;
    final warningGeneration = _cueGeneration;
    final lease = _priority.claimPriority();
    _held = lease;
    _activeCueType = cueType;
    warningError = speechError = null;
    if ((systemBeep && cue.shouldBeep) || cue.shouldVibrate) {
      _cueTimer = Timer.periodic(_intervalForCue(cueType), (_) {
        unawaited(_pulse(cue, warningGeneration,
            heavy: false, systemBeep: systemBeep));
      });
    }
    // Speech cleanup/start and completion cannot delay independent alerts or
    // the caller's subsequent spatial cue. Failures are contained and reported.
    unawaited(() async {
      try {
        await stopping;
        if (speakMessage &&
            cue.needsLocalPlayback &&
            message.isNotEmpty &&
            generation == _generation &&
            !_disposed) {
          await _priority.speakPriority(_voiceOwner, message,
              () => generation == _generation && lease.active && !_disposed);
        }
      } catch (_) {
        if (generation == _generation && !_disposed) {
          speechError = '안전 음성을 재생하지 못했습니다. 경고음·진동은 계속 유지합니다.';
          _report(speechError!);
        }
      }
    }());
    await _pulse(cue, warningGeneration, heavy: true, systemBeep: systemBeep);
  }

  void _report(String message) {
    debugPrint(message);
    try {
      onAudioError?.call(message);
    } catch (_) {/* UI must not stop alerts. */}
  }

  Future<void> _pulse(V3Cue cue, int generation,
      {required bool heavy, required bool systemBeep}) async {
    if (_disposed || generation != _cueGeneration) return;
    // Independent channels: a hung vibrator cannot mute the audible alert.
    await Future.wait([
      if (cue.shouldVibrate)
        _output(true, generation, () => _feedback.vibrate(heavy: heavy)),
      if (systemBeep && cue.shouldBeep)
        _output(false, generation, _feedback.beep),
    ]);
  }

  Future<void> _output(
      bool vibration, int generation, Future<void> Function() start) async {
    if (_disposed ||
        generation != _cueGeneration ||
        (vibration ? _vibrationPending : _beepPending) != null) {
      return;
    }
    try {
      final output = start();
      if (vibration) {
        _vibrationPending = output;
      } else {
        _beepPending = output;
      }
      void release() {
        if (vibration && identical(_vibrationPending, output)) {
          _vibrationPending = null;
        }
        if (!vibration && identical(_beepPending, output)) {
          _beepPending = null;
        }
      }

      // Timeout does not cancel native work; quarantine only this channel
      // until its actual operation settles. Never queue duplicate native calls.
      unawaited(output.then<void>((_) => release(),
          onError: (Object _, StackTrace __) {
        release();
      }));
      await output.timeout(const Duration(seconds: 1));
    } catch (_) {
      _warningFailed(generation);
    }
  }

  void _checkSpeech(int generation) {
    if (_disposed || generation != _generation) throw SpeechCancelled();
  }

  void _warningFailed(int generation) {
    if (_disposed || generation != _cueGeneration || warningError != null) {
      return;
    }
    warningError = '경고음 또는 진동을 재생하지 못했습니다. 출력 장치를 확인해 주세요.';
    _report(warningError!);
  }

  Future<void> playDing({bool vibrate = true}) async {
    if (_disposed) throw SpeechCancelled();
    final stopping = stopCue();
    final generation = _generation;
    await stopping;
    _checkSpeech(generation);
    final lease = await _priority.acquirePriority();
    try {
      _checkSpeech(generation);
      if (vibrate) await HapticFeedback.selectionClick();
      _checkSpeech(generation);
      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {
        await SystemSound.play(SystemSoundType.click);
      }
    } finally {
      lease.release();
    }
  }

  Future<void> speakLocal(String message) async {
    if (_disposed) throw SpeechCancelled();
    if (message.trim().isEmpty) return;
    _shutdown.ensureReady();
    final generation = _generation;
    final lease = await _priority.acquirePriority();
    try {
      _shutdown.ensureReady();
      await _priority.speakPriority(_voiceOwner, message,
          () => !_disposed && generation == _generation && lease.active);
    } finally {
      lease.release();
    }
  }

  Future<void> playGeneratedSpeech(Uint8List audioBytes) async {
    if (_disposed) throw SpeechCancelled();
    final generation = ++_generation;
    final lease = _priority.claimPriority();
    var started = false;
    try {
      await _stopVoiceOutputs();
      _checkSpeech(generation);
      _shutdown.ensureReady();
      _playbackLease = lease;
      _complete = _audioPlayer.onPlayerComplete.listen((_) {
        if (generation == _generation && identical(_playbackLease, lease)) {
          _playbackLease = null;
          lease.release();
        }
      });
      started = true;
      final pending =
          Future<void>.sync(() => _audioPlayer.play(BytesSource(audioBytes)));
      _playerStarting = pending;
      try {
        await pending;
      } finally {
        if (identical(_playerStarting, pending)) _playerStarting = null;
      }
      _checkSpeech(generation);
    } catch (_) {
      if (started && generation == _generation) {
        try {
          await _stopVoiceOutputs();
        } catch (_) {/* quarantine retained */}
      }
      if (_shutdown.confirmed) {
        if (identical(_playbackLease, lease)) _playbackLease = null;
        lease.release();
      } else {
        _retiring.add(lease);
      }
      rethrow;
    }
  }

  Future<void> prepareLiveGeneratedSpeech() async {
    try {
      await _liveAudioPlayer.prepare();
    } catch (_) {/* Existing fallback. */}
  }

  Future<void> playLiveGeneratedSpeech(
      {required String baseUrl,
      required String text,
      void Function()? onFirstAudio}) async {
    if (_disposed) throw SpeechCancelled();
    final generation = ++_generation;
    final lease = _priority.claimPriority();
    var started = false;
    try {
      await _stopVoiceOutputs();
      _checkSpeech(generation);
      _shutdown.ensureReady();
      started = true;
      await _liveAudioPlayer.play(
          baseUrl: baseUrl,
          text: text,
          onFirstAudio: () {
            if (!_disposed && generation == _generation) onFirstAudio?.call();
          });
      _checkSpeech(generation);
      lease.release(); // play returns only after natural drain.
    } catch (_) {
      // A retired run must not stop a newly started run.
      if (generation == _generation && started) {
        try {
          await _stopVoiceOutputs();
        } catch (_) {}
      }
      if (_shutdown.confirmed) {
        lease.release();
      } else {
        _retiring.add(lease);
      }
      rethrow;
    }
  }

  Future<void> stopCue() async {
    _generation++;
    _cueGeneration++;
    _cueTimer?.cancel();
    _cueTimer = null;
    _activeCueType = null;
    final held = _held;
    _held = null;
    if (held != null) _retiring.add(held);
    await _stopVoiceOutputs();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopCue();
    await _audioPlayer.dispose();
    await _liveAudioPlayer.dispose();
  }

  Duration _intervalForCue(String cueType) {
    switch (cueType) {
      case 'TARGET_BUS_NEAR':
      case 'WRONG_BUS_NEAR':
      case 'DANGER':
        return const Duration(milliseconds: 900);
      case 'TARGET_BUS_MID':
      case 'GEOFENCE_WARNING':
        return const Duration(milliseconds: 1600);
      case 'TARGET_BUS_FAR':
        return const Duration(milliseconds: 2600);
      default:
        return const Duration(seconds: 2);
    }
  }

  String _defaultMessage(String cueType) {
    switch (cueType) {
      case 'TARGET_BUS_NEAR':
        return '타야 할 버스가 가까이 왔습니다.';
      case 'TARGET_BUS_MID':
        return '타야 할 버스가 접근 중이에요.';
      case 'TARGET_BUS_FAR':
        return '타야 할 버스가 아직 멀리 있습니다.';
      case 'WRONG_BUS_NEAR':
        return '잘못된 버스가 가까이 왔어요. 기다려 주세요.';
      case 'GEOFENCE_WARNING':
        return '정류장 대기 범위를 벗어났습니다.';
      case 'DANGER':
        return '위험 구역입니다. 즉시 이동해 주세요.';
      default:
        return '';
    }
  }
}
