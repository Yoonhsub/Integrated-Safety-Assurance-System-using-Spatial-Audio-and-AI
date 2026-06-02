import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/v3_guidance_models.dart';
import 'live_audio_player.dart';

class AudioHapticCueService {
  AudioHapticCueService({
    FlutterTts? flutterTts,
    AudioPlayer? audioPlayer,
    LiveAudioPlayer? liveAudioPlayer,
  })  : _flutterTts = flutterTts ?? FlutterTts(),
        _audioPlayer = audioPlayer ?? AudioPlayer(),
        _liveAudioPlayer = liveAudioPlayer ?? LiveAudioPlayer();

  final FlutterTts _flutterTts;
  final AudioPlayer _audioPlayer;
  final LiveAudioPlayer _liveAudioPlayer;
  Timer? _cueTimer;
  String? _activeCueType;
  bool _isConfigured = false;

  String? get activeCueType => _activeCueType;
  bool get isLooping => _cueTimer?.isActive ?? false;

  Future<void> playCue(V3Cue cue, {String? fallbackMessage}) async {
    if (cue.isNone) {
      await stopCue();
      return;
    }

    final cueType = cue.type;
    final message = cue.message ?? fallbackMessage ?? _defaultMessage(cueType);

    if (_activeCueType == cueType && isLooping) {
      return;
    }

    await stopCue();
    _activeCueType = cueType;
    await _configureTts();

    if (cue.shouldVibrate) {
      await HapticFeedback.heavyImpact();
    }

    if (cue.needsLocalPlayback && message.isNotEmpty) {
      await _flutterTts.speak(message);
    }

    if (cue.shouldBeep || cue.shouldVibrate) {
      final interval = _intervalForCue(cueType);
      _cueTimer = Timer.periodic(interval, (_) async {
        if (cue.shouldVibrate) {
          await HapticFeedback.mediumImpact();
        }
        if (cue.shouldBeep) {
          await SystemSound.play(SystemSoundType.click);
        }
      });
    }
  }

  Future<void> playDing({bool vibrate = true}) async {
    await stopCue();
    if (vibrate) {
      await HapticFeedback.selectionClick();
    }
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      await SystemSound.play(SystemSoundType.click);
    }
  }

  Future<void> speakLocal(String message) async {
    if (message.trim().isEmpty) return;
    await _configureTts();
    await _flutterTts.speak(message);
  }

  Future<void> playGeneratedSpeech(Uint8List audioBytes) async {
    await _flutterTts.stop();
    await _audioPlayer.stop();
    await _audioPlayer.play(BytesSource(audioBytes));
  }

  Future<void> prepareLiveGeneratedSpeech() async {
    try {
      await _liveAudioPlayer.prepare();
    } catch (_) {
      // The WAV/local fallback remains available when Web Audio cannot unlock.
    }
  }

  Future<void> playLiveGeneratedSpeech({
    required String baseUrl,
    required String text,
  }) async {
    await _flutterTts.stop();
    await _audioPlayer.stop();
    await _liveAudioPlayer.play(baseUrl: baseUrl, text: text);
  }

  Future<void> stopCue() async {
    _cueTimer?.cancel();
    _cueTimer = null;
    _activeCueType = null;
    await _flutterTts.stop();
    await _audioPlayer.stop();
    await _liveAudioPlayer.stop();
  }

  Future<void> dispose() async {
    await stopCue();
    await _audioPlayer.dispose();
    await _liveAudioPlayer.dispose();
  }

  Future<void> _configureTts() async {
    if (_isConfigured) return;
    await _flutterTts.setLanguage('ko-KR');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setPitch(1.0);
    _isConfigured = true;
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
        return '타야 할 버스가 가까이 왔어.';
      case 'TARGET_BUS_MID':
        return '타야 할 버스가 접근 중이야.';
      case 'TARGET_BUS_FAR':
        return '타야 할 버스가 아직 멀리 있어.';
      case 'WRONG_BUS_NEAR':
        return '잘못된 버스가 가까이 왔어. 기다려.';
      case 'GEOFENCE_WARNING':
        return '정류장 대기 범위를 벗어났어.';
      case 'DANGER':
        return '위험 구역이야. 즉시 이동해.';
      default:
        return '';
    }
  }
}
