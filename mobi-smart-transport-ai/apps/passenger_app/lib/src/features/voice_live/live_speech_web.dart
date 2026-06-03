import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type _MobiSttMic._(JSObject _) implements JSObject {
  external bool supported();
  external void setHandlers(JSFunction onTranscript, JSFunction onState);
  external JSPromise<JSBoolean> start(JSString wsUrl, JSString lang);
  external void setPaused(JSBoolean paused);
  external double getLevel();
  external bool isRunning();
  external JSPromise<JSAny?> stop();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiSttMic')
  external _MobiSttMic? get sttMic;
}

/// 웹 음성 인식기 — 브라우저 Web Speech 대신 **서버 STT**(마이크 PCM → /agent/stt/live
/// → Gemini Live 입력 전사)를 사용한다. 세션을 한 번만 시작하고(연속) 마이크는 계속
/// 열려 있어 iOS/인앱 브라우저의 무제스처 재시작 제약을 우회한다.
class LiveSpeechRecognizer {
  _MobiSttMic? get _api => _MobiWindow._(web.window).sttMic;

  bool get isContinuous => true;
  bool get supported => _api?.supported() ?? false;

  String _wsUrl() {
    final loc = web.window.location;
    final scheme = loc.protocol == 'https:' ? 'wss' : 'ws';
    return '$scheme://${loc.host}/agent/stt/live';
  }

  Future<bool> start({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
    required void Function(String state) onState,
  }) async {
    final api = _api;
    if (api == null) return false;
    void transcriptCb(JSString text, JSBoolean isFinal) =>
        onResult(text.toDart, isFinal.toDart);
    void stateCb(JSString state) => onState(state.toDart);
    api.setHandlers(transcriptCb.toJS, stateCb.toJS);
    try {
      final ok = await api.start(_wsUrl().toJS, localeId.toJS).toDart;
      return ok.toDart;
    } catch (_) {
      return false;
    }
  }

  /// 듣기 활성/비활성(AI 발화 중에는 마이크 전송을 멈춰 에코 전사를 막는다).
  void setActive(bool active) {
    try {
      _api?.setPaused((!active).toJS);
    } catch (_) {}
  }

  double micLevel() {
    final api = _api;
    if (api == null) return 0.0;
    final v = api.getLevel();
    return v.isFinite ? v : 0.0;
  }

  /// 서버 STT는 마이크가 계속 열려 있어 별도 재시작이 필요 없다. 활성화만 보장.
  bool resume() {
    setActive(true);
    return _api?.isRunning() ?? false;
  }

  Future<void> stop() async {
    try {
      await _api?.stop().toDart;
    } catch (_) {}
  }
}
