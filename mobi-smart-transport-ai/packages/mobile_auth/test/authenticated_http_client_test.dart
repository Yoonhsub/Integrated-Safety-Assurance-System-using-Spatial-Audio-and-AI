import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

void main() {
  test('adds bearer token and refreshes once after 401', () async {
    var forcedRefresh = false;
    var requests = 0;
    final api = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async {
        forcedRefresh = forceRefresh;
        return forceRefresh ? 'fresh-token' : 'first-token';
      },
      client: MockClient((request) async {
        requests++;
        expect(request.headers['authorization'], startsWith('Bearer '));
        return http.Response('', requests == 1 ? 401 : 200);
      }),
    );

    final response = await api.get(Uri.parse('https://example.test/private'));

    expect(response.statusCode, 200);
    expect(requests, 2);
    expect(forcedRefresh, isTrue);
  });

  test('does not send a protected request without a token', () async {
    var sent = false;
    final api = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async => null,
      client: MockClient((_) async {
        sent = true;
        return http.Response('', 200);
      }),
    );

    await expectLater(
      api.get(Uri.parse('https://example.test/private')),
      throwsA(isA<AuthenticatedApiException>()),
    );
    expect(sent, isFalse);
  });

  test('distinguishes forbidden and unavailable responses', () async {
    for (final status in [403, 503]) {
      final api = AuthenticatedApiClient(
        tokenLoader: ({bool forceRefresh = false}) async => 'token',
        client: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(
        api.get(Uri.parse('https://example.test/private')),
        throwsA(
          isA<AuthenticatedApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            status,
          ),
        ),
      );
    }
  });
}
