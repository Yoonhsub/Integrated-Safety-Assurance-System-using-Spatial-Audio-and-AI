import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class VoiceGuideService {
  VoiceGuideService({SpeechToText? speechToText, FlutterTts? flutterTts})
    : _speechToText = speechToText ?? SpeechToText(),
      _flutterTts = flutterTts ?? FlutterTts();

  final SpeechToText _speechToText;
  final FlutterTts _flutterTts;

  bool _isInitialized = false;
  String _lastRecognizedWords = '';

  String get lastRecognizedWords => _lastRecognizedWords;

  Future<bool> initialize() async {
    if (_isInitialized) {
      return true;
    }

    _isInitialized = await _speechToText.initialize();
    await _flutterTts.setLanguage('ko-KR');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setPitch(1.0);

    return _isInitialized;
  }

  Future<String> startListening({
    void Function(String recognizedWords)? onResult,
  }) async {
    final isReady = await initialize();

    if (!isReady) {
      return '음성 인식을 사용할 수 없습니다. 마이크 권한과 브라우저 설정을 확인해주세요.';
    }

    _lastRecognizedWords = '';

    await _speechToText.listen(
      localeId: 'ko_KR',
      onResult: (SpeechRecognitionResult result) {
        _lastRecognizedWords = result.recognizedWords;
        onResult?.call(result.recognizedWords);
      },
    );

    return '목적지 입력을 기다리고 있습니다.';
  }

  Future<String> stopListening() async {
    await _speechToText.stop();

    if (_lastRecognizedWords.isEmpty) {
      return '음성 입력이 종료되었습니다.';
    }

    return '인식된 목적지: $_lastRecognizedWords';
  }

  Future<String> speakGuide(String message) async {
    await _flutterTts.speak(message);
    return message;
  }

  Future<void> stopSpeaking() async {
    await _flutterTts.stop();
  }
}
