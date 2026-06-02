import 'package:flutter/foundation.dart';

/// 백엔드 API 기본 URL을 결정한다.
///
/// 우선순위:
/// 1) 빌드 시 `--dart-define=MOBI_API_BASE_URL=...`로 명시한 값.
/// 2) 웹: 현재 페이지 origin(앱과 백엔드가 같은 호스트에서 서비스되므로).
///    → localhost:8000 하드코딩으로 배포본이 백엔드에 못 붙던 문제 방지.
/// 3) 그 외(네이티브 개발): localhost:8000.
String resolveApiBaseUrl() {
  const fromEnv = String.fromEnvironment('MOBI_API_BASE_URL');
  if (fromEnv.isNotEmpty) return fromEnv;
  if (kIsWeb) return Uri.base.origin;
  return 'http://localhost:8000';
}
