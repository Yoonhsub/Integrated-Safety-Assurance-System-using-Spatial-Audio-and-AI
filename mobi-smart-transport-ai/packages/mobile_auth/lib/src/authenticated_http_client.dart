import 'package:http/http.dart' as http;

import 'firebase_auth_service.dart';

typedef IdTokenLoader = Future<String?> Function({bool forceRefresh});
typedef UnauthorizedHandler = Future<void> Function();
typedef RequestGuardFactory = bool Function() Function();

class StaleAuthRequestException extends AuthenticatedApiException {
  const StaleAuthRequestException() : super(499);
  @override
  String get userMessage => '인증 상태가 변경되어 이전 요청을 중단했습니다.';
}

class AuthenticatedApiException implements Exception {
  const AuthenticatedApiException(this.statusCode);
  final int statusCode;

  String get userMessage => switch (statusCode) {
        401 => '로그인 세션이 만료되었습니다. 다시 로그인해 주세요.',
        403 => '이 계정에는 이 작업을 수행할 권한이 없습니다.',
        503 => '인증 서비스를 일시적으로 사용할 수 없습니다. 잠시 후 다시 시도해 주세요.',
        _ => '인증된 API 요청이 실패했습니다 (HTTP $statusCode).',
      };

  @override
  String toString() => userMessage;
}

/// Sends a protected request with a Firebase ID token, refreshing once on 401.
/// The ID token is never included in exceptions or logs.
class AuthenticatedApiClient {
  AuthenticatedApiClient({
    IdTokenLoader? tokenLoader,
    UnauthorizedHandler? onUnauthorized,
    http.Client? client,
    RequestGuardFactory? requestGuard,
  })  : _tokenLoader = tokenLoader ?? FirebaseAuthSession.instance.getIdToken,
        _requestGuard = requestGuard ??
            (tokenLoader == null
                ? FirebaseAuthSession.instance.captureRequestGuard
                : null),
        _onUnauthorized = onUnauthorized,
        _client = client ?? http.Client();

  final IdTokenLoader _tokenLoader;
  final UnauthorizedHandler? _onUnauthorized;
  final http.Client _client;
  final RequestGuardFactory? _requestGuard;

  Future<http.Response> get(Uri uri,
          {Map<String, String>? headers, Future<void>? abortTrigger}) =>
      _send('GET', uri, headers: headers, abortTrigger: abortTrigger);

  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) =>
      _send('POST', uri, headers: headers, body: body);

  Future<http.Response> patch(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) =>
      _send('PATCH', uri, headers: headers, body: body);

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Future<void>? abortTrigger,
  }) async {
    var aborted = false;
    abortTrigger?.then((_) {
      aborted = true;
    });
    final isCurrent = _requestGuard?.call() ?? () => true;
    void check() {
      if (aborted) throw http.RequestAbortedException(uri);
      if (!isCurrent()) throw const StaleAuthRequestException();
    }

    check();
    final token = await _tokenLoader();
    check();
    if (token == null || token.isEmpty) {
      await _onUnauthorized?.call();
      throw const AuthenticatedApiException(401);
    }
    var response =
        await _sendOnce(method, uri, token, headers, body, abortTrigger);
    check();
    if (response.statusCode != 401) {
      _throwForAuthStatus(response.statusCode);
      return response;
    }

    String? refreshed;
    try {
      check();
      refreshed = await _tokenLoader(forceRefresh: true);
    } catch (_) {
      check();
      // Authentication provider details and tokens must not escape to UI/logs.
    }
    check();
    if (refreshed != null && refreshed.isNotEmpty) {
      response =
          await _sendOnce(method, uri, refreshed, headers, body, abortTrigger);
      check();
    }
    if (response.statusCode == 401) await _onUnauthorized?.call();
    _throwForAuthStatus(response.statusCode);
    return response;
  }

  Future<http.Response> _sendOnce(
    String method,
    Uri uri,
    String token,
    Map<String, String>? headers,
    Object? body,
    Future<void>? abortTrigger,
  ) {
    final request = (abortTrigger == null
        ? http.Request(method, uri)
        : http.AbortableRequest(method, uri, abortTrigger: abortTrigger))
      ..headers.addAll(headers ?? const {})
      ..headers['Authorization'] = 'Bearer $token'
      ..followRedirects = false;
    if (body != null) request.body = body.toString();
    return _client.send(request).then(http.Response.fromStream);
  }

  void _throwForAuthStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403 || statusCode == 503) {
      throw AuthenticatedApiException(statusCode);
    }
  }
}
