import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

import 'package:mobi_passenger_app/src/services/backend_api_client.dart';

void main() {
  test('cancellation uses bearer PATCH then reads server state', () async {
    final requests = <http.Request>[];
    final auth = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async => 'test-token',
      client: MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer test-token');
        if (request.method == 'PATCH') {
          expect(jsonDecode(request.body), {'status': 'CANCELLED'});
          expect(request.url.path, '/ride-requests/request-1/status');
        }
        return http.Response(
            jsonEncode({'requestId': 'request-1', 'status': 'CANCELLED'}), 200);
      }),
    );
    final api = BackendApiClient(
        baseUrl: 'http://example.test', useMockData: false, authClient: auth);
    final result = await api.cancelRideRequest('request-1');
    expect(result.isSuccess, isTrue);
    expect(result.statusLabel, 'CANCELLED');
    expect(requests.map((request) => request.method), ['PATCH', 'GET']);
  });

  test('forbidden cancellation is not reported as success', () async {
    final auth = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async => 'test-token',
      client: MockClient((request) async => http.Response('', 403)),
    );
    final api = BackendApiClient(
        baseUrl: 'http://example.test', useMockData: false, authClient: auth);
    await expectLater(api.cancelRideRequest('request-1'),
        throwsA(isA<AuthenticatedApiException>()));
  });
}
