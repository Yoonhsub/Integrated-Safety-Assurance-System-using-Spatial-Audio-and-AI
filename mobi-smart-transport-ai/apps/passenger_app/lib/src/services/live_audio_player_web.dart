import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type _MobiLiveAudio._(JSObject _) implements JSObject {
  external void prepare();
  external void start(JSNumber sampleRate);
  external void feedPcmBase64(JSString data);
  external void finish();
  external void stop();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiLiveAudio')
  external _MobiLiveAudio? get mobiLiveAudio;
}

class LiveAudioPlaybackException implements Exception {
  const LiveAudioPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LiveAudioPlayer {
  web.WebSocket? _socket;

  Future<void> prepare() async {
    _browserPlayer().prepare();
  }

  Future<void> play({
    required String baseUrl,
    required String text,
    void Function()? onFirstAudio,
  }) async {
    await stop();

    final browserPlayer = _browserPlayer();
    browserPlayer.start(24000.toJS);
    var firstAudioSeen = false;

    final socket = web.WebSocket(_websocketUri(baseUrl).toString());
    _socket = socket;
    final completed = Completer<void>();

    void fail(String message) {
      if (!completed.isCompleted) {
        completed.completeError(LiveAudioPlaybackException(message));
      }
    }

    socket.onopen = ((web.Event _) {
      socket.send(jsonEncode(<String, Object?>{'text': text}).toJS);
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      final data = event.data?.dartify();
      if (data is! String) {
        fail('Gemini Live API가 알 수 없는 음성 메시지를 보냈습니다.');
        return;
      }

      final dynamic decoded;
      try {
        decoded = jsonDecode(data);
      } catch (_) {
        fail('Gemini Live API 음성 메시지를 해석하지 못했습니다.');
        return;
      }
      if (decoded is! Map) {
        fail('Gemini Live API 음성 메시지 형식이 올바르지 않습니다.');
        return;
      }

      switch (decoded['type']) {
        case 'start':
          final sampleRate = decoded['sampleRate'];
          if (sampleRate is num) {
            browserPlayer.start(sampleRate.toInt().toJS);
          }
          break;
        case 'audio':
          final audio = decoded['data'];
          if (audio is String && audio.isNotEmpty) {
            if (!firstAudioSeen) {
              firstAudioSeen = true;
              // 첫 오디오 청크 도착 시점 = 실제 소리 시작. 자막을 이때 맞춘다.
              onFirstAudio?.call();
            }
            browserPlayer.feedPcmBase64(audio.toJS);
          }
          break;
        case 'done':
          browserPlayer.finish();
          if (!completed.isCompleted) completed.complete();
          break;
        case 'error':
          fail(decoded['message']?.toString() ??
              'Gemini Live API 음성을 사용할 수 없습니다.');
          break;
      }
    }).toJS;
    socket.onerror = ((web.Event _) {
      fail('Gemini Live API 음성 연결에 실패했습니다.');
    }).toJS;
    socket.onclose = ((web.CloseEvent _) {
      if (!completed.isCompleted) {
        fail('Gemini Live API 음성 연결이 일찍 종료됐습니다.');
      }
    }).toJS;

    try {
      await completed.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const LiveAudioPlaybackException(
        'Gemini Live API 음성 연결 시간이 초과됐습니다.',
      );
    } finally {
      if (identical(_socket, socket)) _socket = null;
      socket.close();
    }
  }

  Future<void> stop() async {
    final socket = _socket;
    _socket = null;
    socket?.close();
    _browserPlayerOrNull()?.stop();
  }

  Future<void> dispose() => stop();

  _MobiLiveAudio _browserPlayer() {
    final browserPlayer = _browserPlayerOrNull();
    if (browserPlayer == null) {
      throw const LiveAudioPlaybackException(
        '브라우저 Live API 음성 플레이어를 찾지 못했습니다.',
      );
    }
    return browserPlayer;
  }

  _MobiLiveAudio? _browserPlayerOrNull() =>
      _MobiWindow._(web.window).mobiLiveAudio;

  Uri _websocketUri(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri.replace(
      scheme: scheme,
      path:
          '${uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path}/agent/tts/live',
      query: null,
      fragment: null,
    );
  }
}
