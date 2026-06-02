import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type _MobiVoiceMic._(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> start();
  external double getLevel();
  external JSPromise<JSAny?> stop();
}

extension type _MobiLiveAudio._(JSObject _) implements JSObject {
  external double getOutputLevel();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiVoiceMic')
  external _MobiVoiceMic? get voiceMic;
  @JS('MobiLiveAudio')
  external _MobiLiveAudio? get liveAudio;
}

/// 웹에서 마이크 입력 RMS(파란 오로라·VAD)와 AI 출력 RMS(주황 오로라)를
/// Web Audio AnalyserNode로 읽어 온다.
class VoiceAudioLevel {
  Future<bool> startMic() async {
    final mic = _MobiWindow._(web.window).voiceMic;
    if (mic == null) return false;
    try {
      final ok = await mic.start().toDart;
      return ok.toDart;
    } catch (_) {
      return false;
    }
  }

  double micLevel() {
    final mic = _MobiWindow._(web.window).voiceMic;
    if (mic == null) return 0.0;
    final value = mic.getLevel();
    return value.isFinite ? value : 0.0;
  }

  double outputLevel() {
    final live = _MobiWindow._(web.window).liveAudio;
    if (live == null) return 0.0;
    final value = live.getOutputLevel();
    return value.isFinite ? value : 0.0;
  }

  Future<void> stopMic() async {
    final mic = _MobiWindow._(web.window).voiceMic;
    if (mic == null) return;
    try {
      await mic.stop().toDart;
    } catch (_) {
      // 정리 실패는 무시한다.
    }
  }
}
