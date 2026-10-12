import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart';
import 'package:mobi_passenger_app/src/services/ride_creation_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const draft = RideRequestDraft(userId: 'u', stopId: 's', routeId: 'r', busNo: '502');
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('unresolved action survives store recreation; confirmed next action gets new key', () async {
    final store = RideCreationIntentStore();
    final key = await store.begin(draft);
    expect(await RideCreationIntentStore().begin(draft), key);
    await store.complete('u', key);
    expect(await store.begin(draft), isNot(key));
  });

  test('different UID isolated and changed unresolved payload blocked', () async {
    final store = RideCreationIntentStore();
    final key = await store.begin(draft);
    expect(await store.begin(const RideRequestDraft(userId: 'other', stopId: 's', routeId: 'r', busNo: '502')), isNot(key));
    await expectLater(store.begin(const RideRequestDraft(userId: 'u', stopId: 'different', routeId: 'r', busNo: '502')), throwsStateError);
  });

  test('401 refresh reuses exact idempotency header and body', () async {
    final keys = <String?>[];
    final bodies = <String>[];
    final auth = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async => 'test-token',
      client: MockClient((request) async {
        keys.add(request.headers['Idempotency-Key']);
        bodies.add(request.body);
        return keys.length == 1 ? http.Response('', 401) : http.Response(jsonEncode({'requestId': 'ride-1', 'status': 'WAITING'}), 200);
      }),
    );
    final api = BackendApiClient(baseUrl: 'http://example.test', useMockData: false, authClient: auth);
    expect((await api.createRideRequest(draft: draft, idempotencyKey: 'stable-test-key-001')).isSuccess, isTrue);
    expect(keys, ['stable-test-key-001', 'stable-test-key-001']);
    expect(bodies[0], bodies[1]);
  });

  test('timeout keeps durable action key for next attempt', () async {
    final store = RideCreationIntentStore();
    final key = await store.begin(draft);
    final auth = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async => 'test-token',
      client: MockClient((request) async => throw TimeoutException('lost reply')),
    );
    final api = BackendApiClient(baseUrl: 'http://example.test', useMockData: false, authClient: auth);
    expect((await api.createRideRequest(draft: draft, idempotencyKey: key)).isSuccess, isFalse);
    expect(await RideCreationIntentStore().begin(draft), key);
  });
}
