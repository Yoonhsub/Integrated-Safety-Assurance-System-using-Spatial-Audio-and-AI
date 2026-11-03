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
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://127.0.0.1:8000';
  }
  return 'http://localhost:8000';
}

/// Normal Android debug uses adb reverse. Release requires an explicit HTTPS
/// origin. No credentials, query strings or permissive LAN cleartext settings.
String? androidApiConfigurationIssue(String value, {required bool release}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !{'', '/'}.contains(uri.path) ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.port < 1 ||
      uri.port > 65535) {
    return '서버 연결 주소가 올바르지 않습니다. 설치 파일 제공자에게 문의해 주세요.';
  }
  final loopback = {'127.0.0.1', 'localhost', '::1'}.contains(uri.host);
  if (release && (uri.scheme != 'https' || loopback)) {
    return '서비스 서버의 HTTPS 주소가 설정되지 않았습니다.';
  }
  if (uri.scheme == 'http' && (release || uri.host != '127.0.0.1')) {
    return '개발 서버 연결은 USB 연결을 통한 로컬 주소만 지원합니다.';
  }
  return null;
}
