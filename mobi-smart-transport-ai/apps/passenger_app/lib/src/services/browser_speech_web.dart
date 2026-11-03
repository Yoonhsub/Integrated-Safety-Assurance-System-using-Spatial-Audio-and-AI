import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'speech_engine.dart';

extension type _BrowserTts(JSObject _) implements JSObject {
  external void prepare(JSBoolean korean);
  external JSPromise<JSBoolean> speak(JSString text);
  external JSPromise<JSBoolean> stop();
}
extension type _SpeechWindow(JSObject _) implements JSObject {
  @JS('MobiTts')
  external _BrowserTts? get tts;
}

class BrowserSpeechEngine implements SpeechEngine {
  _BrowserTts get _tts =>
      _SpeechWindow(web.window).tts ?? (throw StateError('브라우저 음성 어댑터가 없습니다'));
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {
    _tts.prepare(requireKoreanVoice.toJS);
  }

  @override
  Future<void> speak(String text) async {
    if (!(await _tts.speak(text.toJS).toDart).toDart) throw SpeechCancelled();
  }

  @override
  Future<void> stop() async {
    if (!(await _tts.stop().toDart).toDart) {
      throw StateError('브라우저 음성 종료를 확인할 수 없습니다');
    }
  }
}

SpeechEngine? createBrowserSpeechEngine() => BrowserSpeechEngine();
