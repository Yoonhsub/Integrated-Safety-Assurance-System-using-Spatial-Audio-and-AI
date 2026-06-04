import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_coords.dart';

extension type _MobiGeoResult._(JSObject _) implements JSObject {
  external double get lat;
  external double get lng;
  external double get acc;
}

extension type _MobiGeoError._(JSObject _) implements JSObject {
  external int get code;
  external String get message;
}

extension type _MobiGeo._(JSObject _) implements JSObject {
  external JSPromise<_MobiGeoResult?> getPosition();
  external void startWatch();
  external _MobiGeoResult? getCached();
  external _MobiGeoError? getLastError();
}

extension type _MobiWindow._(JSObject _) implements JSObject {
  @JS('MobiGeo')
  external _MobiGeo? get geo;
}

/// 지속 위치 추적(watchPosition)을 한 번 시작한다. 권한이 있으면 첫 fix가 도착하는
/// 즉시 캐시가 채워지고 이후 계속 갱신된다.
void startWebGeoWatch() {
  try {
    _MobiWindow._(web.window).geo?.startWatch();
  } catch (_) {}
}

/// watch가 캐시해 둔 최신 좌표(있으면). 동기 — 즉시 반환.
WebCoords? webGeoCached() {
  final geo = _MobiWindow._(web.window).geo;
  if (geo == null) return null;
  try {
    final c = geo.getCached();
    if (c == null) return null;
    final lat = c.lat;
    final lng = c.lng;
    if (!lat.isFinite || !lng.isFinite) return null;
    return WebCoords(lat, lng, c.acc.isFinite ? c.acc : 0.0);
  } catch (_) {
    return null;
  }
}

/// 마지막 geolocation 에러를 사람이 읽을 수 있는 문자열로(없으면 null).
/// code: 1 권한 거부 / 2 위치 불가 / 3 시간 초과.
String? webGeoError() {
  final geo = _MobiWindow._(web.window).geo;
  if (geo == null) return null;
  try {
    final e = geo.getLastError();
    if (e == null) return null;
    final code = e.code;
    final label = switch (code) {
      1 => '위치 권한이 거부됨',
      2 => '위치를 확인할 수 없음',
      3 => '위치 확인 시간 초과',
      _ => '위치 오류',
    };
    return '$label (code $code)';
  } catch (_) {
    return null;
  }
}

/// 관대한 옵션의 raw navigator.geolocation 폴백(일회성).
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
