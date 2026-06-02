import 'web_coords.dart';

/// 비-웹: raw 웹 위치를 쓸 수 없으므로 항상 null(기본 geolocator 경로 사용).
Future<WebCoords?> getWebCoords() async => null;
