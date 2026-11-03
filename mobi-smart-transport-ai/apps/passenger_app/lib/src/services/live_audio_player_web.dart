import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'live_audio_session.dart';
export 'live_audio_session.dart'
    show LiveAudioPlaybackException, LiveAudioState;

extension type _MobiLiveAudio(JSObject _) implements JSObject {
  external void prepare();
  external void start(JSNumber sampleRate);
  external void feedPcmBase64(JSString data);
  external JSPromise<JSBoolean> finish();
  external void stop();
}
extension type _MobiWindow(JSObject _) implements JSObject {
  @JS('MobiLiveAudio')
  external _MobiLiveAudio? get mobiLiveAudio;
}

class _WebOutput implements LiveAudioOutput {
  _MobiLiveAudio? get _optional => _MobiWindow(web.window).mobiLiveAudio;
  _MobiLiveAudio get _api =>
      _optional ??
      (throw const LiveAudioPlaybackException('브라우저 음성 플레이어가 없습니다.'));
  @override
  Future<void> prepare() async => _api.prepare();
  @override
  void start(int rate) => _api.start(rate.toJS);
  @override
  void feed(String pcm) => _api.feedPcmBase64(pcm.toJS);
  @override
  Future<bool> finish() async => (await _api.finish().toDart).toDart;
  @override
  Future<void> stop() async => _optional?.stop();
}

class _WebConnection implements LiveAudioConnection {
  _WebConnection(Uri uri) : socket = web.WebSocket(uri.toString());
  final web.WebSocket socket;
  @override
  set onOpen(void Function() callback) {
    socket.onopen = ((web.Event _) => callback()).toJS;
  }

  @override
  set onMessage(void Function(Object?) callback) {
    socket.onmessage =
        ((web.MessageEvent event) => callback(event.data?.dartify())).toJS;
  }

  @override
  set onError(void Function() callback) {
    socket.onerror = ((web.Event _) => callback()).toJS;
  }

  @override
  set onClose(void Function() callback) {
    socket.onclose = ((web.CloseEvent _) => callback()).toJS;
  }

  @override
  void send(String text) => socket.send(text.toJS);
  @override
  void close() => socket.close();
}

class LiveAudioPlayer extends LiveAudioSession {
  LiveAudioPlayer() : super(output: _WebOutput(), connect: _WebConnection.new);
}
