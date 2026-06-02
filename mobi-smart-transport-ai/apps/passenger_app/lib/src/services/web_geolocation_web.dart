import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_coords.dart';

extension type _MobiGeoResult._(JSObject _) implements JSObject {
  external double get lat;
  external double get lng;
  external double get acc;
}

extension type _MobiGeo._(JSObject _) implements JSObject {
  external JSPromise<_MobiGeoResult?> getPosition();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiGeo')
  external _MobiGeo? get geo;
}

/// 관대한 옵션의 raw navigator.geolocation 폴백.
Future<WebCoords?> getWebCoords() async {
  final geo = _MobiWindow._(web.window).geo;
  if (geo == null) return null;
  try {
    final result = await geo.getPosition().toDart;
    if (result == null) return null;
    final lat = result.lat;
    final lng = result.lng;
    if (!lat.isFinite || !lng.isFinite) return null;
    return WebCoords(lat, lng, result.acc.isFinite ? result.acc : 0.0);
  } catch (_) {
    return null;
  }
}
