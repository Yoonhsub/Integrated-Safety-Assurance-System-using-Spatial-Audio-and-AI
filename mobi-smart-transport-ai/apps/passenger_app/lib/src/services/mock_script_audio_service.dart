import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../mock_scenario/mock_script_lines.dart';
import '../mock_scenario/mock_voice_assets.dart';

class MockScriptAudioService {
  MockScriptAudioService({
    AudioPlayer? audioPlayer,
    FlutterTts? flutterTts,
    this.webClipPlayer,
    this.webClipStop,
  }) : _audioPlayer = audioPlayer ?? AudioPlayer(),
       _flutterTts = flutterTts ?? FlutterTts();

  /// 웹(특히 iOS)에서 beep와 동일한 AudioContext로 음성 mp3를 재생하는 경로.
  /// 자산 경로('mock_voice/x.mp3')와 공간 파라미터를 받아 재생 완료 시 true.
  /// null이면 audioplayers 사용.
  final Future<bool> Function(String assetPath, double pan, double gain)?
  webClipPlayer;
  final Future<void> Function()? webClipStop;

  final AudioPlayer _audioPlayer;
  final FlutterTts _flutterTts;
  bool _ttsConfigured = false;
  String? _lastScriptLineId;
  String? _lastSpokenText;
  double _lastSpatialPan = 0;
  double _lastSpatialGain = 1;

  // 현재 재생 중인 클립이 끝날 때까지 기다리기 위한 completer/구독.
  Completer<void>? _playbackCompleter;
  StreamSubscription<void>? _completeSub;

  String? get lastScriptLineId => _lastScriptLineId;
  String? get lastSpokenText => _lastSpokenText;

  /// 한 줄의 안내 음성을 재생하고 **재생이 끝날 때까지 await**한다.
  /// 호출자(시나리오 컨트롤러)가 이 Future로 타임라인을 음성 길이에 맞춰 멈췄다 재개한다.
  Future<void> playScript(
    String scriptLineId, {
    String? fallbackText,
    double spatialPan = 0,
    double spatialGain = 1,
  }) async {
    final line = mockScriptLineById(scriptLineId);
    final text = fallbackText ?? line?.text ?? scriptLineId;
    _lastScriptLineId = scriptLineId;
    _lastSpokenText = text;
    _lastSpatialPan = spatialPan.clamp(-1.0, 1.0).toDouble();
    _lastSpatialGain = spatialGain.clamp(0.0, 1.3).toDouble();
    // 이전 재생을 확실히 멈춰 두 음성이 겹치지 않게 한다.
    await stop();

    final assetPath =
        mockVoiceAssetPathForText(text) ??
        line?.assetPath ??
        mockVoiceAssetPathForScriptId(scriptLineId);
    if (assetPath != null) {
      // 웹: beep와 같은 컨텍스트로 재생(컨텍스트 충돌 회피). 실패 시 audioplayers로 폴백.
      if (webClipPlayer != null &&
          await webClipPlayer!(assetPath, _lastSpatialPan, _lastSpatialGain)) {
        return;
      }
      if (await _playAsset(assetPath)) {
        return;
      }
    }

    await speakText(text);
  }

  Future<void> repeatLast() async {
    final id = _lastScriptLineId;
    if (id != null) {
      await playScript(
        id,
        fallbackText: _lastSpokenText,
        spatialPan: _lastSpatialPan,
        spatialGain: _lastSpatialGain,
      );
      return;
    }
    final text = _lastSpokenText;
    if (text != null && text.trim().isNotEmpty) {
      await speakText(text);
    }
  }

  /// 기기 TTS 폴백. 자산이 없을 때만 사용되며, awaitSpeakCompletion 덕분에
  /// 발화가 끝날 때까지 await된다.
  Future<void> speakText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _lastSpokenText = trimmed;
    await _configureTts();
    await _flutterTts.speak(trimmed);
  }

  Future<void> stop() async {
    _completeSub?.cancel();
    _completeSub = null;
    final completer = _playbackCompleter;
    _playbackCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    if (webClipStop != null) {
      await webClipStop!();
    }
    await _audioPlayer.stop();
    await _flutterTts.stop();
  }

  /// 자산(mp3)을 재생하고 **자연 종료(onPlayerComplete)까지 기다린다**.
  /// 중간에 stop()이 불리면 completer가 완료되어 즉시 반환한다.
  Future<bool> _playAsset(String assetPath) async {
    try {
      final completer = Completer<void>();
      _playbackCompleter = completer;
      _completeSub?.cancel();
      _completeSub = _audioPlayer.onPlayerComplete.listen((_) {
        if (!completer.isCompleted) completer.complete();
      });
      await _audioPlayer.play(AssetSource(assetPath));
      // 안전장치: 완료 이벤트가 유실돼도 무한 대기하지 않도록 상한을 둔다.
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {},
      );
      return true;
    } catch (error) {
      debugPrint('Mock voice asset playback failed: $assetPath ($error)');
      return false;
    } finally {
      _completeSub?.cancel();
      _completeSub = null;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _audioPlayer.dispose();
  }

  Future<void> _configureTts() async {
    if (_ttsConfigured) return;
    await _flutterTts.setLanguage('ko-KR');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setPitch(1.0);
    // speak()가 발화 종료까지 await되도록 설정(폴백 음성도 겹치지 않게).
    await _flutterTts.awaitSpeakCompletion(true);
    _ttsConfigured = true;
  }
}
