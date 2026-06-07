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
  external void setHeadOrientation(
    JSNumber yaw,
    JSNumber pitch,
    JSNumber roll,
    JSBoolean enabled,
  );
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

  Future<void> setHeadTracking({
    required bool enabled,
    double? yaw,
    double? pitch,
    double? roll,
  }) async {
    try {
      _api?.setHeadOrientation(
        (yaw ?? 0).toJS,
        (pitch ?? 0).toJS,
        (roll ?? 0).toJS,
        enabled.toJS,
      );
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stopCue();
  }
}
