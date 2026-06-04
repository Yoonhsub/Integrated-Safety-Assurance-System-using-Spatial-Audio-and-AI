import 'web_coords.dart';

/// 비-웹: raw 웹 위치를 쓸 수 없으므로 항상 null(기본 geolocator 경로 사용).
Future<WebCoords?> getWebCoords() async => null;

/// 비-웹: no-op (네이티브는 geolocator의 위치 스트림을 쓴다).
void startWebGeoWatch() {}

/// 비-웹: 캐시 없음.
WebCoords? webGeoCached() => null;

/// 비-웹: 에러 없음.
String? webGeoError() => null;
