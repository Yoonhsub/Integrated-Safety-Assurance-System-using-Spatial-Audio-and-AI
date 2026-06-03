import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type _MobiSttMic._(JSObject _) implements JSObject {
  external double getLevel();
}

extension type _MobiLiveAudio._(JSObject _) implements JSObject {
  external double getOutputLevel();
  external double getRemainingMs();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiSttMic')
  external _MobiSttMic? get sttMic;
  @JS('MobiLiveAudio')
  external _MobiLiveAudio? get liveAudio;
}

/// 웹 오디오 레벨: 마이크 RMS(파란 오로라)는 서버 STT용 마이크(MobiSttMic)에서,
/// AI 출력 RMS·재생 잔여(주황 오로라/드레인)는 MobiLiveAudio에서 읽는다.
/// 마이크 자체는 음성 인식기(LiveSpeechRecognizer)가 열고 닫으므로 여기선 no-op.
class VoiceAudioLevel {
  Future<bool> startMic() async => true;

  double micLevel() {
    final mic = _MobiWindow._(web.window).sttMic;
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

  double remainingPlaybackMs() {
    final live = _MobiWindow._(web.window).liveAudio;
    if (live == null) return 0.0;
    final value = live.getRemainingMs();
    return value.isFinite ? value : 0.0;
  }

  Future<void> stopMic() async {}
}
