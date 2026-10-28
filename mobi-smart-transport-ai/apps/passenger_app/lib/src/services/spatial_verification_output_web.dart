import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'spatial_verification_engine.dart';
import 'directional_guidance.dart';

extension type _Graph(JSObject _) implements JSObject {
  external JSPromise<JSAny?> prepare();
  external JSPromise<JSBoolean> play(JSString mode, JSString direction);
  external JSPromise<JSBoolean> playCue(JSString direction);
  external JSPromise<JSBoolean> stop();
  external JSPromise<JSAny?> dispose();
  external JSString snapshot();
}
extension type _Window(JSObject _) implements JSObject {
  @JS('MobiSpatialVerification')
  external _Graph? get graph;
}

class WebSpatialTestOutput implements SpatialTestOutput, DirectionalCueOutput {
  _Graph get _api =>
      _Window(web.window).graph ??
      (throw StateError('Local verification graph absent'));
  @override
  Future<void> prepareFromGesture() async {
    await _api.prepare().toDart;
  }

  @override
  Future<bool> play(String mode, String direction) async =>
      (await _api.play(mode.toJS, direction.toJS).toDart).toDart;
  @override
  Future<bool> playCue(TestDirection direction) async =>
      (await _api.playCue(direction.name.toUpperCase().toJS).toDart).toDart;
  @override
  Future<void> stop() async {
    if (!(await _api.stop().toDart).toDart) {
      throw StateError('Spatial stop unconfirmed');
    }
  }

  @override
  Future<void> dispose() async {
    await _api.dispose().toDart;
  }

  @override
  Map<String, dynamic> snapshot() {
    try {
      return Map<String, dynamic>.from(
          jsonDecode(_api.snapshot().toDart) as Map);
    } catch (_) {
      return {'phase': 'unavailable'};
    }
  }
}
