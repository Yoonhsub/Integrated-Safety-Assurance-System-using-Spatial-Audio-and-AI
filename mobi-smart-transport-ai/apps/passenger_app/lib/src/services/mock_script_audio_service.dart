import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../mock_scenario/mock_script_lines.dart';
import '../mock_scenario/mock_voice_assets.dart';

class MockScriptAudioService {
  MockScriptAudioService({AudioPlayer? audioPlayer, FlutterTts? flutterTts})
    : _audioPlayer = audioPlayer ?? AudioPlayer(),
      _flutterTts = flutterTts ?? FlutterTts();

  final AudioPlayer _audioPlayer;
  final FlutterTts _flutterTts;
  bool _ttsConfigured = false;
  String? _lastScriptLineId;
  String? _lastSpokenText;

  String? get lastScriptLineId => _lastScriptLineId;
  String? get lastSpokenText => _lastSpokenText;

  Future<void> playScript(String scriptLineId, {String? fallbackText}) async {
    final line = mockScriptLineById(scriptLineId);
    final text = fallbackText ?? line?.text ?? scriptLineId;
    _lastScriptLineId = scriptLineId;
    _lastSpokenText = text;
    await stop();

    final assetPath =
        mockVoiceAssetPathForText(text) ??
        line?.assetPath ??
        mockVoiceAssetPathForScriptId(scriptLineId);
    if (assetPath != null && await _playAsset(assetPath)) {
      return;
    }

    await speakText(text);
  }

  Future<void> repeatLast() async {
    final id = _lastScriptLineId;
    if (id != null) {
      await playScript(id, fallbackText: _lastSpokenText);
      return;
    }
    final text = _lastSpokenText;
    if (text != null && text.trim().isNotEmpty) {
      await speakText(text);
    }
  }

  Future<void> speakText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _lastSpokenText = trimmed;
    await _configureTts();
    await _flutterTts.speak(trimmed);
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
    await _flutterTts.stop();
  }

  Future<bool> _playAsset(String assetPath) async {
    try {
      await _audioPlayer.play(AssetSource(assetPath));
      return true;
    } catch (error) {
      debugPrint('Mock voice asset playback failed: $assetPath ($error)');
      return false;
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
    _ttsConfigured = true;
  }
}
