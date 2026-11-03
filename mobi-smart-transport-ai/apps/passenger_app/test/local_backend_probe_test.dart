import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_passenger_app/local_android_backend_main.dart' as entry;
import 'package:mobi_passenger_app/src/local_backend/local_backend_probe.dart';

void main() {
  test('entry is Android explicit-debug-only',
      () => expect(entry.main, throwsStateError));
  for (final url in [
    'http://localhost:8000',
    'http://10.0.2.2:8000',
    'https://127.0.0.1:8000',
    'http://127.0.0.1:8001',
    'http://127.0.0.1:8000/x',
    'http://user@127.0.0.1:8000',
    'http://127.0.0.1:8000?x=1'
  ]) {
    test('reject configuration $url',
        () => expect(() => validateLocalBackend(url), throwsStateError));
  }
  test('guard rejects cloud, Safety Events, camera upload and redirects',
      () async {
    var calls = 0;
    final trace = <Map<String, Object?>>[];
    final client = LocalBackendTransport(MockClient((r) async {
      calls++;
      expect(r.followRedirects, false);
      return http.Response('{}', 302);
    }), trace.add);
    for (final uri in [
      'https://example.invalid/guidance/state',
      'http://127.0.0.1:8000/ai-vision/events',
      'http://127.0.0.1:8000/safety-events',
      'http://127.0.0.1:8000/guidance/state?auth=bad'
    ]) {
      await expectLater(client.get(Uri.parse(uri)), throwsStateError);
    }
    await client.get(Uri.parse('http://127.0.0.1:8000/health'));
    expect(calls, 1);
    expect(trace.toString(), isNot(contains('Authorization')));
    client.close();
  });
  test('existing API and receiver create, reset, end with isolated owners',
      () async {
    var generation = 1, ended = false, posts = 0;
    final client = MockClient((r) async {
      final path = r.url.path, identity = r.headers['authorization'];
      http.Response json(Object v, int status) =>
          http.Response(jsonEncode(v), status, headers: {
            'content-type': 'application/json',
            'x-mobi-local-probe': 'fake-auth-memory-v1'
          });
      if (path == '/health') return json({'status': 'ok'}, 200);
      if (identity == null) return json({}, 401);
      if (identity == 'Bearer offline-only.other') return json({}, 403);
      if (path == '/guidance/session') posts++;
      if (path == '/guidance/reset') generation++;
      if (path == '/guidance/event' &&
          jsonDecode(r.body)['event'] == 'BOARDED') {
        ended = true;
      }
      if (path == '/guidance/safety-events') {
        return ended
            ? json({}, 403)
            : json({
                'sessionId': 's',
                'ownerUid': 'owner',
                'generation': 'g$generation',
                'cursor': 0,
                'events': []
              }, 200);
      }
      return json({
        'sessionId': 's',
        'state': ended ? 'BOARDED' : 'IDLE',
        'wakeWord': 'local',
        'geofenceArmed': false,
        'updatedAt': '2026-10-29T00:00:00Z'
      }, 200);
    });
    final probe =
        LocalBackendProbe(baseUrl: 'http://127.0.0.1:8000', transport: client);
    await probe.verify();
    expect(probe.status, contains('PASS'));
    expect(posts, 1);
    expect(probe.generation, 'g2');
    expect(probe.receiver!.enabled, false);
    await probe.endSession();
    expect(probe.status, contains('거부 PASS'));
    expect(ended, true);
    probe.dispose();
    probe.dispose();
  });
  for (final code in [401, 403, 500]) {
    test('HTTP$code stops workflow without duplicate POST', () async {
      var posts = 0;
      final probe = LocalBackendProbe(
          baseUrl: 'http://127.0.0.1:8000',
          transport: MockClient((r) async {
            if (r.url.path == '/health') {
              return http.Response('{}', 200,
                  headers: {'x-mobi-local-probe': 'fake-auth-memory-v1'});
            }
            if (r.headers['authorization'] == null) {
              return http.Response('{}', 401);
            }
            posts++;
            return http.Response('{}', code);
          }));
      await probe.verify();
      expect(posts,
          code == 401 ? 2 : 1); // existing one refresh retry on current401
      expect(probe.receiver, isNull);
      expect(probe.busy, false);
      probe.dispose();
    });
  }
  test('ordinary Backend health cannot cause fixture credentials to be sent',
      () async {
    var calls = 0;
    final probe = LocalBackendProbe(
        baseUrl: 'http://127.0.0.1:8000',
        transport: MockClient((r) async {
          calls++;
          expect(r.headers.containsKey('authorization'), false);
          return http.Response('{}', 200);
        }));
    await probe.verify();
    expect(calls, 1);
    expect(probe.status, contains('BLOCKED'));
    probe.dispose();
  });
  test('refused server never starts session mutation', () async {
    var posts = 0;
    final probe = LocalBackendProbe(
        baseUrl: 'http://127.0.0.1:8000',
        transport: MockClient((r) async {
          if (r.method == 'POST') posts++;
          throw http.ClientException('fixture refusal');
        }));
    await probe.verify();
    expect(posts, 0);
    expect(probe.status, contains('BLOCKED'));
    probe.dispose();
  });
  test(
      'same UID epoch change discards a delayed response and starts no next request',
      () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final probe = LocalBackendProbe(
        baseUrl: 'http://127.0.0.1:8000',
        transport: MockClient((r) {
          calls++;
          return pending.future;
        }));
    final work = probe.verify();
    await Future<void>.delayed(Duration.zero);
    probe.relogin();
    pending.complete(http.Response('{}', 200));
    await work;
    expect(calls, 1);
    expect(probe.sessionId, isEmpty);
    expect(probe.status, '새 Fake 로그인 세대');
    probe.dispose();
  });
  testWidgets(
      'health timeout produces no session POST; late completion is harmless',
      (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final probe = LocalBackendProbe(
        baseUrl: 'http://127.0.0.1:8000',
        transport: MockClient((r) {
          calls++;
          return pending.future;
        }));
    final work = probe.verify();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await work;
    expect(calls, 1);
    expect(probe.status, contains('BLOCKED'));
    probe.dispose();
    pending.complete(http.Response('{}', 200));
    await tester.pump();
  });
  test('dispose during HTTP prevents further sends and UI changes', () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final probe = LocalBackendProbe(
        baseUrl: 'http://127.0.0.1:8000',
        transport: MockClient((r) {
          calls++;
          return pending.future;
        }));
    final work = probe.verify();
    await Future<void>.delayed(Duration.zero);
    probe.dispose();
    pending.complete(http.Response('{}', 200));
    await work;
    expect(calls, 1);
    expect(probe.sessionId, isEmpty);
  });
}
