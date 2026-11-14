import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';

enum TagoDiagnosticStatus {
  success,
  empty,
  fallback,
  unavailable,
  unauthorized,
  forbidden,
  unsupported,
  invalidInput,
  timeout,
  malformed,
  error
}

class TagoDiagnosticResult {
  const TagoDiagnosticResult(
      {required this.status,
      required this.message,
      this.source = 'UNKNOWN',
      this.records = const [],
      this.warnings = const [],
      this.httpStatus,
      this.receivedAt,
      this.updatedAt,
      this.fetchedAt,
      this.errorCode,
      this.totalCount,
      this.truncated = false});
  final TagoDiagnosticStatus status;
  final String message, source;
  final List<Map<String, Object?>> records;
  final List<String> warnings;
  final int? httpStatus, totalCount;
  final String? errorCode;
  final bool truncated;

  /// Client receipt and backend fetch are not physical observation times.
  final DateTime? receivedAt, fetchedAt;
  final DateTime? updatedAt;
  DateTime? get observedAt => updatedAt;
}

class TagoDiagnosticsClient {
  TagoDiagnosticsClient(
      {required this.baseUrl,
      AuthenticatedApiClient? authClient,
      http.Client? publicClient,
      this.timeout = const Duration(seconds: 15)})
      : _ownedAuthHttp = authClient == null ? http.Client() : null,
        _ownsPublic = publicClient == null,
        _public = publicClient ?? http.Client() {
    _auth = authClient ??
        AuthenticatedApiClient(
            client: _ownedAuthHttp,
            onUnauthorized: FirebaseAuthSession.instance.signOut);
  }
  final String baseUrl;
  final Duration timeout;
  late final AuthenticatedApiClient _auth;
  final http.Client? _ownedAuthHttp;
  final http.Client _public;
  final bool _ownsPublic;
  bool _closed = false;
  String get backendOrigin => Uri.parse(baseUrl).origin;
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsPublic) _public.close();
    _ownedAuthHttp?.close();
  }

  Uri _uri(String path, Map<String, String>? query) {
    final base = Uri.parse(baseUrl);
    if (!{'http', 'https'}.contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const FormatException();
    }
    return Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}$path')
        .replace(queryParameters: query);
  }

  Future<TagoDiagnosticResult> health() => _read('/health', public: true);
  Future<TagoDiagnosticResult> arrivals(
          {required String cityCode, required String stopId}) =>
      _query('arrivals', cityCode, 'stopId', stopId);
  Future<TagoDiagnosticResult> locations(
          {required String cityCode, required String routeId}) =>
      _query('locations', cityCode, 'routeId', routeId);

  Future<TagoDiagnosticResult> _query(
      String operation, String city, String key, String id) async {
    if (!RegExp(r'^[0-9]{1,6}$').hasMatch(city.trim()) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id.trim())) {
      return const TagoDiagnosticResult(
          status: TagoDiagnosticStatus.invalidInput,
          message: '도시 코드는 숫자 1~6자리, ID는 영문·숫자·밑줄·하이픈 1~64자로 입력해 주세요.');
    }
    return _read('/diagnostics/tago/$operation',
        query: {'cityCode': city.trim(), key: id.trim()});
  }

  Future<TagoDiagnosticResult> _read(String path,
      {bool public = false, Map<String, String>? query}) async {
    if (_closed) {
      return const TagoDiagnosticResult(
          status: TagoDiagnosticStatus.unavailable,
          message: '진단 화면이 종료되어 조회하지 않았습니다.');
    }
    try {
      final uri = _uri(path, query);
      final response =
          await (public ? _public.get(uri) : _auth.get(uri)).timeout(timeout);
      if (_closed) {
        return const TagoDiagnosticResult(
            status: TagoDiagnosticStatus.unavailable,
            message: '종료된 진단의 응답을 표시하지 않습니다.');
      }
      final received = DateTime.now().toUtc();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return TagoDiagnosticResult(
            status: _httpStatus(response.statusCode),
            httpStatus: response.statusCode,
            receivedAt: received,
            message: response.statusCode == 404
                ? '이 서버 버전은 별도 TAGO 진단 API를 지원하지 않습니다. 모의 자료로 대체하지 않았습니다.'
                : '백엔드 요청에 실패했습니다 (HTTP ${response.statusCode}).');
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) throw const FormatException();
      if (public) {
        if (body['status'] != 'ok') throw const FormatException();
        return TagoDiagnosticResult(
            status: TagoDiagnosticStatus.success,
            message: '백엔드 연결 성공. TAGO 데이터 조회 성공이나 인증 성공을 의미하지 않습니다.',
            source: 'BACKEND',
            httpStatus: response.statusCode,
            receivedAt: received,
            records: [
              Map.unmodifiable({
                'status': 'ok',
                if (body['dataMode'] == 'live' || body['dataMode'] == 'mock')
                  'dataMode': body['dataMode']
              })
            ]);
      }
      final source =
          {'PUBLIC_API', 'ERROR', 'MOCK', 'CACHE'}.contains(body['source'])
              ? body['source'] as String
              : 'UNKNOWN';
      // Validate query echo: data from a different city or ID is not a result.
      if (body['cityCode'] != query!['cityCode'] ||
          (query.containsKey('stopId') && body['stopId'] != query['stopId']) ||
          (query.containsKey('routeId') &&
              body['routeId'] != query['routeId'])) {
        throw const FormatException();
      }
      if (body['fallbackUsed'] is! bool || body['provider'] != 'TAGO') {
        throw const FormatException();
      }
      final rows = body['records'];
      if (rows is! List || rows.any((e) => e is! Map)) {
        throw const FormatException();
      }
      final fallback =
          body['fallbackUsed'] == true || source == 'MOCK' || source == 'CACHE';
      final outcome = body['status'];
      if (!{'SUCCESS', 'EMPTY', 'ERROR'}.contains(outcome)) {
        throw const FormatException();
      }
      if ((outcome == 'EMPTY' && rows.isNotEmpty) ||
          (outcome == 'SUCCESS' && rows.isEmpty)) {
        throw const FormatException();
      }
      if (!fallback &&
          source == 'PUBLIC_API' &&
          (body['provider'] != 'TAGO' || body['fallbackUsed'] != false)) {
        throw const FormatException();
      }
      final records = <Map<String, Object?>>[];
      for (final row in rows.cast<Map>()) {
        bool identity(String key) =>
            row[key] is String &&
            (row[key] as String).trim().isNotEmpty &&
            (row[key] as String).length <= 256;
        if (path.endsWith('/arrivals') &&
            !identity('routeId') &&
            !identity('routeNo')) {
          throw const FormatException();
        }
        if (path.endsWith('/locations') &&
            ((!identity('nodeId') && !identity('nodeName')) ||
                row['positionType'] != 'LAST_REPORTED_STOP')) {
          throw const FormatException();
        }
        final safe = <String, Object?>{};
        for (final key in [
          'routeNo',
          'routeId',
          'busId',
          'nodeId',
          'nodeName',
          'vehicleType'
        ]) {
          final value = row[key];
          if (value is String && value.length <= 256) safe[key] = value;
        }
        if (row['positionType'] == 'LAST_REPORTED_STOP') {
          safe['positionType'] = 'LAST_REPORTED_STOP';
        }
        for (final key in ['arrivalSeconds', 'remainingStops']) {
          final value = row[key];
          if (value is int && value >= 0) safe[key] = value;
        }
        records.add(Map.unmodifiable(safe));
      }
      DateTime? time(Object? value) {
        final parsed = value is String &&
                RegExp(r'(Z|[+-][0-9]{2}:[0-9]{2})$').hasMatch(value)
            ? DateTime.tryParse(value)
            : null;
        return parsed != null && !parsed.isAfter(received) ? parsed : null;
      }

      final code = const {
        'SERVICE_KEY_MISSING',
        'UPSTREAM_TIMEOUT',
        'UPSTREAM_UNAVAILABLE',
        'PROVIDER_REJECTED',
        'MALFORMED_RESPONSE'
      }.contains(body['errorCode'])
          ? body['errorCode'] as String
          : null;
      final status = fallback
          ? TagoDiagnosticStatus.fallback
          : source != 'PUBLIC_API' || outcome == 'ERROR'
              ? TagoDiagnosticStatus.unavailable
              : outcome == 'EMPTY'
                  ? TagoDiagnosticStatus.empty
                  : TagoDiagnosticStatus.success;
      final message = switch (status) {
        TagoDiagnosticStatus.success =>
          '공공 API 자료를 받았습니다. 실제 차량 식별이나 탑승 확인은 아닙니다.',
        TagoDiagnosticStatus.empty =>
          '공공 API 응답에 항목이 없습니다. 운행 종료나 버스 부재를 확정하지 않습니다.',
        TagoDiagnosticStatus.fallback => '대체 자료가 반환되어 실데이터 조회 성공으로 보지 않습니다.',
        _ => switch (code) {
            'SERVICE_KEY_MISSING' =>
              '서버의 TAGO 서비스 키 설정이 필요합니다. 앱에는 키를 입력하지 마세요.',
            'UPSTREAM_TIMEOUT' => 'TAGO 응답 시간이 초과됐습니다. 잠시 후 다시 조회해 주세요.',
            'PROVIDER_REJECTED' =>
              'TAGO가 요청을 거부했습니다. 서버의 키 권한과 조회 ID를 확인해 주세요.',
            'MALFORMED_RESPONSE' => 'TAGO 응답 형식을 확인할 수 없습니다.',
            _ => '공공 API 조회를 확인할 수 없습니다. 서버 설정과 연결을 확인해 주세요.',
          },
      };
      return TagoDiagnosticResult(
          status: status,
          message: message,
          source: source,
          records: List.unmodifiable(records),
          receivedAt: received,
          fetchedAt: time(body['fetchedAt']),
          updatedAt: time(body['observedAt']),
          errorCode: code,
          httpStatus: response.statusCode,
          totalCount: body['totalCount'] is int && body['totalCount'] >= 0
              ? body['totalCount']
              : null,
          truncated: body['truncated'] == true,
          warnings: [
            '수신·조회 시각은 차량의 실제 관측 시각이 아닙니다.',
            if (time(body['observedAt']) == null)
              '관측 시각이 제공되지 않아 자료의 실제 최신 여부는 확인할 수 없습니다.',
            if (path.endsWith('/locations'))
              '위치는 마지막 보고 정류장 정보이며 GPS 좌표나 현재 위치가 아닙니다.',
            if (body['truncated'] == true) '일부 항목만 표시됩니다. 전체 결과로 해석하지 마세요.'
          ]);
    } on TimeoutException {
      return const TagoDiagnosticResult(
          status: TagoDiagnosticStatus.timeout,
          message: '조회 시간이 초과됐습니다. 연결을 확인한 뒤 다시 조회해 주세요.');
    } on AuthenticatedApiException catch (error) {
      return TagoDiagnosticResult(
          status: _httpStatus(error.statusCode),
          message: error.userMessage,
          httpStatus: error.statusCode);
    } on FormatException {
      return const TagoDiagnosticResult(
          status: TagoDiagnosticStatus.malformed,
          message: '응답 형식 또는 백엔드 주소를 확인할 수 없습니다.');
    } catch (_) {
      return const TagoDiagnosticResult(
          status: TagoDiagnosticStatus.error,
          message: '백엔드에 연결할 수 없습니다. 네트워크와 서버 주소 설정을 확인해 주세요.');
    }
  }

  TagoDiagnosticStatus _httpStatus(int code) => switch (code) {
        401 => TagoDiagnosticStatus.unauthorized,
        403 => TagoDiagnosticStatus.forbidden,
        404 => TagoDiagnosticStatus.unsupported,
        422 => TagoDiagnosticStatus.invalidInput,
        503 => TagoDiagnosticStatus.unavailable,
        _ => TagoDiagnosticStatus.error,
      };
}
