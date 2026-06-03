import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type _MobiSpeech._(JSObject _) implements JSObject {
  external bool supported();
  external void setHandlers(JSFunction onResult, JSFunction onState);
  external bool start(JSString localeId);
  external bool resume();
  external void stop();
  external bool isRunning();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiSpeech')
  external _MobiSpeech? get mobiSpeech;
}

/// 웹 연속 음성 인식기(webkitSpeechRecognition, continuous=true).
/// 세션을 한 번만 시작하고 턴 사이에 멈추지 않아, iOS/인앱 브라우저의 무제스처
/// 재시작 차단으로 두 번째 턴부터 인식이 씹히던 문제를 피한다.
class LiveSpeechRecognizer {
  _MobiSpeech? get _api => _MobiWindow._(web.window).mobiSpeech;

  /// 연속 인식 여부. 웹은 true(턴마다 stop/restart 안 함).
  bool get isContinuous => true;

  bool get supported => _api?.supported() ?? false;

  /// 사용자 제스처(버튼 탭) 컨텍스트에서 호출해야 모바일에서 확실히 시작된다.
  Future<bool> start({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(String state) onState,
  }) async {
    final api = _api;
    if (api == null) return false;
    void resultCb(JSString text, JSBoolean isFinal) =>
        onResult(text.toDart, isFinal.toDart);
    void stateCb(JSString state) => onState(state.toDart);
    api.setHandlers(resultCb.toJS, stateCb.toJS);
    try {
      return api.start(localeId.toJS);
    } catch (_) {
      return false;
    }
  }

  /// 자동 재시작이 막힌 뒤 사용자 탭으로 다시 시작.
  bool resume() {
    final api = _api;
    if (api == null) return false;
    try {
      return api.resume();
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      _api?.stop();
    } catch (_) {}
  }
}
