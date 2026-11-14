import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/services/tago_diagnostics_client.dart';

void main() {
  Map<String, Object?> envelope(
          {String source = 'PUBLIC_API',
          String status = 'SUCCESS',
          List<Object?>? records}) =>
      {
        'source': source,
        'status': status,
        'provider': 'TAGO',
        'cityCode': '33010',
        'stopId': 'CJB1',
        'routeId': 'CJB2',
        'fallbackUsed': false,
        'records': records ??
            [
              {'routeNo': '502', 'arrivalSeconds': 60}
            ],
        'fetchedAt': '2020-01-01T00:00:00Z',
        'observedAt': null,
        'truncated': false,
        'totalCount': 1,
      };
  TagoDiagnosticsClient client(
      Future<http.Response> Function(http.Request) send,
      {Duration timeout = const Duration(seconds: 1),
      String? token = 'test'}) {
    final transport = MockClient(send);
    return TagoDiagnosticsClient(
        baseUrl: 'https://configured.example',
        timeout: timeout,
        publicClient: transport,
        authClient: AuthenticatedApiClient(
            client: transport,
            tokenLoader: ({bool forceRefresh = false}) async => token));
  }

  Future<TagoDiagnosticResult> arrivals(TagoDiagnosticsClient api) =>
      api.arrivals(cityCode: '33010', stopId: 'CJB1');
  test('exact city-aware GET authenticated and no mode mutations', () async {
    final api = client((r) async {
      expect(r.method, 'GET');
      expect(r.url.path, '/diagnostics/tago/arrivals');
      expect(r.url.queryParameters, {'cityCode': '33010', 'stopId': 'CJB1'});
      expect(r.headers['Authorization'], 'Bearer test');
      return http.Response(jsonEncode(envelope()), 200);
    });
    final result = await arrivals(api);
    expect(result.status, TagoDiagnosticStatus.success);
    expect(result.updatedAt, isNull);
    expect(result.fetchedAt!.year, 2020);
    expect(result.receivedAt, isNotNull);
  });
  test('locations use exact route and no GPS promise', () async {
    final api = client((r) async {
      expect(r.url.path, '/diagnostics/tago/locations');
      expect(r.url.queryParameters, {'cityCode': '33010', 'routeId': 'CJB2'});
      return http.Response(
          jsonEncode(envelope(records: [
            {
              'nodeName': 'Stop' ,
              'positionType': 'LAST_REPORTED_STOP',
              'latitude': 37.0
            }
          ])),
          200);
    });
    final result = await api.locations(cityCode: '33010', routeId: 'CJB2');
    expect(result.records.single.containsKey('latitude'), isFalse);
    expect(result.warnings.join(), contains('GPS'));
  });
  test('health public reachability is not provider or auth verification',
      () async {
    final api = client((r) async {
      expect(r.headers.containsKey('Authorization'), isFalse);
      return http.Response(
          '{"status":"ok","dataMode":"live","secret":"hidden"}', 200);
    });
    final result = await api.health();
    expect(result.source, 'BACKEND');
    expect(result.message, contains('의미하지'));
    expect(result.records.toString(), isNot(contains('hidden')));
  });
  test('mock cache unknown cannot be live success', () async {
    for (final source in ['MOCK', 'CACHE', 'UNKNOWN', 'ERROR']) {
      final result = await arrivals(client((_) async =>
          http.Response(jsonEncode(envelope(source: source)), 200)));
      expect(result.status, isNot(TagoDiagnosticStatus.success));
    }
  });
  test('empty is distinct and no operation ended assertion', () async {
    final result = await arrivals(client((_) async => http.Response(
        jsonEncode(envelope(status: 'EMPTY', records: [])), 200)));
    expect(result.status, TagoDiagnosticStatus.empty);
    expect(result.message, contains('확정하지'));
  });
  test('malformed and mismatched provenance fail closed', () async {
    for (final patch in [
      {'cityCode': '11'},
      {'provider': 'OTHER'},
      {'fallbackUsed': null},
      {'status': 'LIVE'},
      {'records': null},
      {
        'records': [{}]
      },
      {'status': 'EMPTY'}
    ]) {
      final result = await arrivals(client((_) async =>
          http.Response(jsonEncode({...envelope(), ...patch}), 200)));
      expect(result.status, TagoDiagnosticStatus.malformed);
    }
  });
  test('future or absent observation stays unknown and old remains old',
      () async {
    for (final value in [
      null,
      'bad',
      '2020-01-01T00:00:00',
      '2999-01-01T00:00:00Z',
      '2020-01-01T00:00:00Z'
    ]) {
      final result = await arrivals(client((_) async => http.Response(
          jsonEncode({...envelope(), 'observedAt': value}), 200)));
      expect(result.updatedAt?.year,
          value == '2020-01-01T00:00:00Z' ? 2020 : null);
    }
  });
  test('old server unsupported no alternative API request or mock', () async {
    var calls = 0;
    final result = await arrivals(client((_) async {
      calls++;
      return http.Response('secret response', 404);
    }));
    expect(calls, 1);
    expect(result.status, TagoDiagnosticStatus.unsupported);
    expect(result.message, isNot(contains('secret response')));
  });
  test('401 refresh stays unauthorized and no secrets escape', () async {
    var calls = 0;
    final result = await arrivals(client((_) async {
      calls++;
      return http.Response('private token data', 401);
    }));
    expect(calls, 2);
    expect(result.status, TagoDiagnosticStatus.unauthorized);
    expect(result.message, isNot(contains('private')));
  });
  test('invalid input and missing login never contact server', () async {
    var calls = 0;
    final api = client((_) async {
      calls++;
      return http.Response('{}', 200);
    }, token: null);
    expect((await api.arrivals(cityCode: 'abc', stopId: 'CJB1')).status,
        TagoDiagnosticStatus.invalidInput);
    expect((await arrivals(api)).status, TagoDiagnosticStatus.unauthorized);
    expect(calls, 0);
  });
  test('provider failures sanitized and timestamp never fabricated', () async {
    final result = await arrivals(client((_) async => http.Response(
        jsonEncode({
          ...envelope(status: 'ERROR', source: 'ERROR', records: []),
          'errorCode': 'SERVICE_KEY_MISSING',
          'message': 'private key value',
          'fetchedAt': null
        }),
        200)));
    expect(result.status, TagoDiagnosticStatus.unavailable);
    expect(result.errorCode, 'SERVICE_KEY_MISSING');
    expect(result.message, isNot(contains('private key')));
    expect(result.updatedAt, isNull);
  });
  test('truncated disclosed and records whitelist', () async {
    final result = await arrivals(client((_) async => http.Response(
        jsonEncode({
          ...envelope(records: [
            {'routeNo': '502', 'secret': 'hidden'}
          ]),
          'truncated': true
        }),
        200)));
    expect(result.truncated, isTrue);
    expect(result.records.toString(), isNot(contains('hidden')));
  });
  test('closed client stops new queries', () async {
    var calls = 0;
    final api = client((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    api.close();
    expect((await arrivals(api)).status, TagoDiagnosticStatus.unavailable);
    expect(calls, 0);
  });
}
