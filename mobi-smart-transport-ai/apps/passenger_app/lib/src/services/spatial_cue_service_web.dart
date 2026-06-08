import 'dart:js_interop';

import 'package:web/web.dart' as web;

extension type _MobiSpatialCue._(JSObject _) implements JSObject {
  external void prepare();
  external void startCue(
    JSNumber pan,
    JSNumber gain,
    JSNumber intervalMs,
    JSString pattern,
  );
  external void updateCue(
    JSNumber pan,
    JSNumber gain,
    JSNumber intervalMs,
    JSString pattern,
  );
  external void stop();
  external void alarm(JSString pattern);
  external JSPromise<JSAny?> playClip(
    JSString url,
    JSNumber pan,
    JSNumber gain,
  );
  external void updateClipSpatial(JSNumber pan, JSNumber gain);
  external void stopClip();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiSpatialCue')
  external _MobiSpatialCue? get spatialCue;
}

class SpatialCueService {
  bool _active = false;

  _MobiSpatialCue? get _api => _MobiWindow._(web.window).spatialCue;

  Future<void> prepare() async {
    try {
      _api?.prepare();
    } catch (_) {}
  }

  Future<void> startCue({
    required double pan,
    required double gain,
    required int intervalMs,
    required String pattern,
  }) async {
    try {
      final api = _api;
      if (api == null) return;
      api.prepare();
      api.startCue(pan.toJS, gain.toJS, intervalMs.toJS, pattern.toJS);
      _active = true;
    } catch (_) {}
  }

  Future<void> updateCue({
    required double pan,
    required double gain,
    required int intervalMs,
    required String pattern,
  }) async {
    try {
      final api = _api;
      if (api == null) return;
      if (!_active) {
        await startCue(
          pan: pan,
          gain: gain,
          intervalMs: intervalMs,
          pattern: pattern,
        );
        return;
      }
      api.updateCue(pan.toJS, gain.toJS, intervalMs.toJS, pattern.toJS);
    } catch (_) {}
  }

  Future<void> stopCue() async {
    try {
      _api?.stop();
      _active = false;
    } catch (_) {}
  }

  Future<void> playAlarm({String pattern = 'alarm'}) async {
    try {
      final api = _api;
      if (api == null) return;
      api.prepare();
      api.alarm(pattern.toJS);
      _active = true;
    } catch (_) {}
  }

  /// 안내 음성 mp3를 beep와 동일한 AudioContext에서 재생하고 완료까지 기다린다.
  /// (iOS 동시 AudioContext 충돌로 음성 재생 중 beep가 멈추던 문제 회피)
  Future<bool> playClip(String url, {double pan = 0, double gain = 1}) async {
    final api = _api;
    if (api == null) return false;
    try {
      await api.playClip(url.toJS, pan.toJS, gain.toJS).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> updateClipSpatial({
    required double pan,
    required double gain,
  }) async {
    try {
      _api?.updateClipSpatial(pan.toJS, gain.toJS);
    } catch (_) {}
  }

  Future<void> stopClip() async {
    try {
      _api?.stopClip();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stopCue();
    await stopClip();
  }
}
