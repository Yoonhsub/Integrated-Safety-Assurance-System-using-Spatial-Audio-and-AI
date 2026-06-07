import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/v3_guidance_models.dart';

extension type _MobiHeadTracking._(JSObject _) implements JSObject {
  external bool supported();
  external JSPromise<JSAny?> connect();
  external JSPromise<JSAny?> disconnect();
  external void resetZero();
  external JSString getSnapshotJson();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiHeadTracking')
  external _MobiHeadTracking? get headTracking;
}

class HeadTrackingService {
  _MobiHeadTracking? get _api => _MobiWindow._(web.window).headTracking;

  bool get supported {
    try {
      return _api?.supported() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<HeadTrackingDebugSnapshot> connect() async {
    final api = _api;
    if (api == null || !supported) {
      return const HeadTrackingDebugSnapshot(
        statusLabel: 'Web Bluetooth unavailable',
        isAvailable: false,
        sourceLabel: 'WT901BLE Web Bluetooth',
      );
    }
    try {
      await api.connect().toDart;
      return snapshot();
    } catch (error) {
      return HeadTrackingDebugSnapshot(
        statusLabel: _connectErrorLabel(error),
        isAvailable: false,
        sourceLabel: 'WT901BLE Web Bluetooth',
      );
    }
  }

  HeadTrackingDebugSnapshot snapshot() {
    final api = _api;
    if (api == null) return HeadTrackingDebugSnapshot.disabled();
    try {
      final jsonText = api.getSnapshotJson().toDart;
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        return HeadTrackingDebugSnapshot.disabled();
      }
      return HeadTrackingDebugSnapshot.fromJson(decoded);
    } catch (_) {
      return const HeadTrackingDebugSnapshot(
        statusLabel: 'snapshot parse failed',
        isAvailable: false,
        sourceLabel: 'WT901BLE Web Bluetooth',
      );
    }
  }

  void resetZero() {
    try {
      _api?.resetZero();
    } catch (_) {}
  }

  Future<void> disconnect() async {
    try {
      await _api?.disconnect().toDart;
    } catch (_) {}
  }

  String _connectErrorLabel(Object error) {
    final text = error.toString();
    if (text.contains('NotFoundError')) return 'device selection cancelled';
    if (text.contains('NotAllowedError')) return 'bluetooth permission denied';
    if (text.contains('NotSupportedError')) return 'bluetooth unsupported';
    return 'connect failed';
  }
}
