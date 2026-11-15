import 'vision_observation_test.dart' as wire;
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:mobi_passenger_app/src/services/shared_guidance_session.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';

V3GuidanceState state([String id = 'session-a']) => V3GuidanceState.fromJson({
      'sessionId': id,
      'state': 'WAITING_FOR_BUS',
      'selectedRouteId': 'route-105',
      'selectedStopId': 'stop-a',
      'selectedRouteNo': '105',
    });
void main() {
  for (final leased in [false, true]) {
    test('resume uses existing server session, leased=$leased', () async {
      final transport = wire.LeaseTestTransport();
      final api = wire.leaseClient(wire.LeaseTestLogin(), transport, enabled: leased);
      final resumed = await api.resumeSession(sessionId: 's');
      expect(resumed.sessionId, 's');
      expect(transport.requests.any((r) => r.url.path == '/guidance/state'), true);
      expect(transport.requests.any((r) => r.url.path == '/guidance/session'), false);
      expect(transport.issues, leased ? 1 : 0);
      if (leased) expect(api.visionSessionReady('s'), true);
    });
  }

  test('rapid route and vision entry share one pending creation', () async {
    final store = SharedGuidanceSession()..bind('user');
    final pending = Completer<V3GuidanceState>();
    var creates = 0;
    Future<V3GuidanceState> create() { creates++; return pending.future; }
    final first = store.open(create: create, fetch: (_) async => state());
    final second = store.open(create: create, fetch: (_) async => state());
    pending.complete(state());
    expect((await first).sessionId, (await second).sessionId);
    expect(creates, 1);
  });
  test('route snapshot persists then is discarded on server reset', () async {
    final store = SharedGuidanceSession()..bind('user');
    final plan = V3RoutePlanResponse.fromJson({'status': 'OK'});
    store.save(store.generation, state(), plan);
    await store.open(create: () async => state(), fetch: (_) async => state());
    expect(store.routePlan, same(plan));
    await store.open(create: () async => state(), fetch: (_) async =>
      V3GuidanceState.fromJson({'sessionId': 'session-a', 'state': 'IDLE'}));
    expect(store.routePlan, isNull);
  });
  test('home and vision reuse same session; server state is refreshed',
      () async {
    final store = SharedGuidanceSession()..bind('user|server|live');
    var creates = 0;
    Future<V3GuidanceState> create() async {
      creates++;
      return state();
    }

    await store.open(
        create: create, fetch: (_) async => throw StateError('unexpected'));
    store.bind('user|server|live');
    final result = await store.open(
        create: create,
        fetch: (id) async {
          expect(id, 'session-a');
          return state();
        });
    expect(creates, 1);
    expect(result.selectedRouteId, 'route-105');
    expect(result.selectedStopId, 'stop-a');
  });
  test('logout invalidates late writes including same-user re-login', () {
    final store = SharedGuidanceSession()..bind('user');
    final old = store.generation;
    store.save(old, state(), null);
    store.clear();
    store.bind('user');
    store.save(old, state(), null);
    expect(store.state, isNull);
    expect(store.routePlan, isNull);
  });
  test('account or server changes discard prior state', () {
    final store = SharedGuidanceSession()..bind('user|server1');
    store.save(store.generation, state(), null);
    store.bind('user|server2');
    expect(store.state, isNull);
  });
  for (final code in [401, 403, 404, 410]) {
    test('terminal HTTP $code discards session without creating replacement',
        () async {
      final store = SharedGuidanceSession()..bind('user');
      store.save(store.generation, state(), null);
      await expectLater(
          store.open(
              create: () async => fail('must not create'),
              fetch: (_) async =>
                  throw V3ApiException('unavailable', statusCode: code)),
          throwsA(isA<V3ApiException>()));
      expect(store.state, isNull);
      expect(store.routePlan, isNull);
    });
  }
  test('transient network failure retains session but does not admit it',
      () async {
    final store = SharedGuidanceSession()..bind('user');
    store.save(store.generation, state(), null);
    await expectLater(
        store.open(
            create: () async => fail('must not create'),
            fetch: (_) async => throw const V3ApiException('timeout')),
        throwsA(isA<V3ApiException>()));
    expect(store.state!.sessionId, 'session-a');
  });
  test('logout while fetch pending cannot resurrect state', () async {
    final store = SharedGuidanceSession()..bind('user');
    store.save(store.generation, state(), null);
    final pending = Completer<V3GuidanceState>();
    final request =
        store.open(create: () async => state(), fetch: (_) => pending.future);
    final assertion = expectLater(request, throwsStateError);
    store.clear();
    pending.complete(state());
    await assertion;
    expect(store.state, isNull);
  });
  test('mismatched server session is rejected', () async {
    final store = SharedGuidanceSession()..bind('user');
    store.save(store.generation, state(), null);
    await expectLater(
        store.open(
            create: () async => state(), fetch: (_) async => state('wrong')),
        throwsStateError);
    expect(store.state, isNull);
  });
}
