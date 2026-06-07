import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

/// 비-웹(네이티브)용: speech_to_text 기반. 네이티브 STT는 무제스처 재시작 제약이
/// 없으므로 턴마다 다시 듣는다(비연속).
class LiveSpeechRecognizer {
  final SpeechToText _speech = SpeechToText();
  void Function(String text, bool isFinal)? _onResult;
  void Function(String state)? _onState;
  String _locale = 'ko_KR';
  bool _ready = false;
  bool _active = false;

  bool get isContinuous => false;
  bool get supported => true;
  bool get needsRecovery => false;

  Future<bool> start({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(String state) onState,
  }) async {
    _onResult = onResult;
    _onState = onState;
    _locale = localeId;
    _ready = await _speech.initialize(
      onStatus: (s) => _onState?.call(s),
      onError: (_) => _onState?.call('error'),
    );
    if (!_ready) return false;
    _active = true;
    _listen();
    return true;
  }

  void _listen() {
    if (!_ready || !_active) return;
    _speech.listen(
      localeId: _locale,
      pauseFor: const Duration(seconds: 3),
      listenFor: const Duration(seconds: 120),
      onResult: (SpeechRecognitionResult r) =>
          _onResult?.call(r.recognizedWords, r.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  void setActive(bool active) {
    _active = active;
    if (!active && _speech.isListening) {
      _speech.cancel();
    }
  }

  bool resume() {
    if (!_ready) return false;
    _active = true;
    if (_speech.isListening) return true;
    _listen();
    return true;
  }

  Future<void> stop() async {
    _active = false;
    try {
      await _speech.cancel();
    } catch (_) {}
  }
}
