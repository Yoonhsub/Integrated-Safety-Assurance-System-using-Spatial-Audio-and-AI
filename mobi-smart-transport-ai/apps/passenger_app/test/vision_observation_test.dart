import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/widgets/vision_observation_panel.dart';

void main() {
  leaseNegotiationTests();
  test('normal app camera is user initiated and uses passenger lease only',
      () async {
    final login = LeaseTestLogin();
    final transport = PhoneTestTransport();
    final api = leaseClient(login, transport, enabled: false);
    await api.createSession(wakeWord: 'test');
    expect(transport.issues, 0);
    final binding = await api.startPassengerCamera('s');
    expect(transport.issues, 1);
    expect(binding['producerId'], 'owner');
    await api.sendPassengerCamera(
        binding,
        {
          'frameId': '00000000-0000-4000-8000-000000000010',
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          'source': 'android_camera',
          'detections': [],
        },
        0);
    expect(transport.uploads, 1);
    api.invalidateVisionSession('s');
    await api.stopPassengerCamera(binding);
    expect(transport.stops, 1);
    await expectLater(api.sendPassengerCamera(binding, {}, 1),
        throwsA(isA<VisionLeaseException>()));
    expect(transport.uploads, 1);
    expect(
        transport.requests.any((r) => r.url.path == '/ai-vision/v2/bindings'),
        false);
  });

  test('camera setup outage does not block ordinary Guidance', () async {
    final login = LeaseTestLogin();
    final transport = LeaseTestTransport()..status = 503;
    final api = leaseClient(login, transport, enabled: false);
    await expectLater(
        api.startPassengerCamera('s'), throwsA(isA<VisionLeaseException>()));
    transport.status = 200;
    await api.fetchState(sessionId: 's');
    expect(transport.requests.last.url.path, '/guidance/state');
    expect(transport.requests.last.headers.containsKey('X-Mobi-Vision-Lease'),
        false);
  });

  testWidgets('Android observation provenance is not displayed as webcam',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's',
            fetch: (_) async => {
                  'sessionId': 's',
                  'observations': [
                    {
                      'state': 'available',
                      'validForSeconds': 3.0,
                      'sourceType': 'android_camera',
                      'observedClasses': ['bus'],
                      'receivedAt': 'fixture'
                    }
                  ]
                })));
    await tester.pump();
    expect(find.text('Android 카메라 형식 입력 · 촬영 시각 미검증'), findsOneWidget);
    expect(find.text('웹캠 입력 · 촬영 시각 미검증'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  Map<String, dynamic> value(String state, {double ttl = 3}) => {
        'sessionId': 's',
        'observations': [
          {
            'state': state,
            'validForSeconds': ttl,
            'sourceType': 'replay',
            'observedClasses': ['bus'],
            'receivedAt': 'test',
          },
        ],
      };
  testWidgets(
    'replay observation is display only and duplicate polling replaces content',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VisionObservationPanel(
            sessionId: 's',
            fetch: (_) async => value('available'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('버스가 감지되었습니다'), findsOneWidget);
      expect(find.text('녹화 영상 기반 시연 정보입니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('버스가 감지되었습니다'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('expired data is not presented as a current bus', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VisionObservationPanel(
          sessionId: 's',
          fetch: (_) async => value('available', ttl: 0),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsNothing);
    expect(find.text('현재 관찰 정보가 없습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('lost and query failure clear current observations', (
    tester,
  ) async {
    var fail = false;
    await tester.pumpWidget(
      MaterialApp(
        home: VisionObservationPanel(
          sessionId: 's',
          fetch: (_) async {
            if (fail) throw Exception('unauthorized');
            return value('lost');
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('카메라 연결이 중단되었습니다'), findsOneWidget);
    fail = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('카메라 연결이 중단되었습니다'), findsNothing);
    expect(find.text('현재 관찰 정보가 없습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('account change drops a late response from the previous user', (
    tester,
  ) async {
    final changes = StreamController<String?>();
    final pending = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(
      MaterialApp(
        home: VisionObservationPanel(
          sessionId: 's',
          ownerUid: 'alice',
          authChanges: changes.stream,
          fetch: (_) => pending.future,
        ),
      ),
    );
    changes.add('bob');
    await tester.pump();
    pending.complete(value('available'));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsNothing);
    expect(find.text('현재 관찰 정보가 없습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    unawaited(changes.close());
    await tester.pump();
  });
  testWidgets('bus door observation is displayed without boarding permission', (
    tester,
  ) async {
    final data = value('available');
    (data['observations'] as List)[0]['observedClasses'] = ['bus', 'bus_door'];
    await tester.pumpWidget(
      MaterialApp(
        home: VisionObservationPanel(sessionId: 's', fetch: (_) async => data),
      ),
    );
    await tester.pump();
    expect(find.text('버스와 버스 문이 감지되었습니다'), findsOneWidget);
    expect(find.textContaining('안전하게 승차'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

class LeaseTestLogin {
  Object scope = Object();
  int epoch = 0;
  VisionLeaseLogin capture() {
    final now = epoch;
    return VisionLeaseLogin(
        scope: scope, uid: 'owner', isCurrent: () => epoch == now);
  }

  void login() {
    epoch++;
    scope = Object();
  }
}

class LeaseTestTransport extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final bodies = <Map<String, dynamic>>[];
  Map<String, dynamic>? ticket;
  String? lose;
  String generation = 'g1';
  int issues = 0, registrations = 0, status = 200;
  bool expired = false;
  int viewRevision = 0;
  Map<String, dynamic> Function(Map<String, dynamic>, http.BaseRequest)?
      transformSnapshot;
  Completer<void>? pause;
  String? pausePath;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    requests.add(r);
    final b = r is http.Request && r.body.isNotEmpty
        ? jsonDecode(r.body) as Map<String, dynamic>
        : <String, dynamic>{};
    bodies.add(b);
    if (r.url.path == pausePath) await pause!.future;
    dynamic value;
    var code = status;
    if (code == 200) {
      switch (r.url.path) {
        case '/guidance/vision-lease/operations':
          registrations++;
          ticket ??= {
            'operationId': b['operationId'],
            'startTicket': 't' * 43,
            'version': 1,
            'activeVersion': 0,
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 15))
                .toUtc()
                .toIso8601String()
          };
          value = ticket;
          code = 201;
        case '/guidance/vision-lease':
          if (r.method == 'POST') {
            issues++;
            code = 201;
          }
          value = {
            'leaseId': 'l' * 43,
            'ownerUid': 'owner',
            'status': 'active',
            'version': 1,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'expiresAt': DateTime.now()
                .add(Duration(minutes: expired ? -1 : 15))
                .toUtc()
                .toIso8601String()
          };
          if (r.method == 'DELETE') code = 204;
        case '/guidance/session':
          value = {'sessionId': 's', 'state': 'IDLE'};
        case '/guidance/reset':
          generation = 'g2';
          value = {'sessionId': 's', 'state': 'IDLE'};
        case '/guidance/safety-events':
          value = {
            'sessionId': 's',
            'ownerUid': 'owner',
            'generation': generation,
            'cursor': 0,
            'events': []
          };
        default:
          value = {
            'sessionId': 's',
            'ownerUid': 'owner',
            'generation': generation,
            'leaseVersion': 1,
            'authority': '00000000-0000-4000-8000-000000000001',
            'viewRevision': viewRevision,
            'bindings': [],
            'observations': []
          };
      }
    }
    if (r.url.path.endsWith('/observations') && value is Map<String, dynamic>) {
      value = transformSnapshot?.call(value, r) ?? value;
    }
    if (lose == r.url.path) {
      lose = null;
      throw http.ClientException('Injected response loss');
    }
    return http.StreamedResponse(
        Stream.value(utf8.encode(code == 204 ? '' : jsonEncode(value ?? {}))),
        code);
  }
}

V3AgentApiClient leaseClient(LeaseTestLogin login, http.Client transport,
        {String origin = 'http://127.0.0.1:18441', bool enabled = true}) =>
    V3AgentApiClient(
        baseUrl: origin,
        visionLeaseEnabled: enabled,
        visionLogin: login.capture,
        authClient: AuthenticatedApiClient(
            client: transport,
            tokenLoader: ({bool forceRefresh = false}) async =>
                'local-test-only',
            requestGuard: () => login.capture().isCurrent));

void leaseNegotiationTests() {
  Map<String, dynamic> preview() => {
        'sessionId': 's',
        'observations': [
          {
            'state': 'available',
            'validForSeconds': 3.0,
            'sourceType': 'replay',
            'observedClasses': ['bus'],
            'receivedAt': 'test'
          }
        ]
      };
  testWidgets(
      'lease: reset admission wait does not permanently stop panel polling',
      (tester) async {
    var ready = true, version = 0;
    late StateSetter rebuild;
    await tester
        .pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, set) {
      rebuild = set;
      return VisionObservationPanel(
          sessionId: 's',
          scopeVersion: version,
          fetch: (_) async {
            if (!ready) throw const VisionLeaseException(blocked: true);
            return preview();
          });
    })));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsOneWidget);
    rebuild(() {
      version++;
      ready = false;
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsNothing);
    ready = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('lease: terminal polling stops until explicit new session scope',
      (tester) async {
    var denied = true, version = 0, calls = 0;
    late StateSetter rebuild;
    await tester
        .pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, set) {
      rebuild = set;
      return VisionObservationPanel(
          sessionId: 's',
          scopeVersion: version,
          fetch: (_) async {
            calls++;
            if (denied) throw const VisionLeaseException(terminal: true);
            return preview();
          });
    })));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 1);
    rebuild(() {
      version++;
      denied = false;
    });
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(calls, greaterThan(2));
    expect(find.text('버스가 감지되었습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final bad in [
    'missing',
    'negative',
    'string',
    'bool',
    'fraction',
    'owner',
    'epoch'
  ]) {
    test('revision: malformed $bad snapshot is fail closed', () async {
      final login = LeaseTestLogin(), t = LeaseTestTransport();
      final a = leaseClient(login, t);
      await a.createSession(wakeWord: 'test');
      t.transformSnapshot = (packet, r) {
        if (bad == 'missing') packet.remove('viewRevision');
        if (bad == 'negative') packet['viewRevision'] = -1;
        if (bad == 'string') packet['viewRevision'] = '1';
        if (bad == 'bool') packet['viewRevision'] = true;
        if (bad == 'fraction') packet['viewRevision'] = 1.5;
        if (bad == 'owner') packet['ownerUid'] = 'other';
        if (bad == 'epoch') {
          packet['bindings'] = [
            {
              'cameraId': 'c',
              'bindingId': 'invalid',
              'bindingRevision': 1,
              'sessionId': 's'
            }
          ];
        }
        return packet;
      };
      await expectLater(
          a.fetchVisionObservations('s'), throwsA(isA<VisionLeaseException>()));
    });
  }
  test('revision: remote mutation discards old snapshot but next poll resumes',
      () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final a = leaseClient(login, t);
    await a.createSession(wakeWord: 'test');
    t.transformSnapshot = (packet, r) {
      if (r.url.queryParameters['proofOnly'] == 'true') {
        packet['viewRevision'] = 1;
      }
      return packet;
    };
    await expectLater(
        a.fetchVisionObservations('s'),
        throwsA(isA<VisionLeaseException>()
            .having((e) => e.blocked, 'blocked', true)));
    t.viewRevision = 1;
    t.transformSnapshot = null;
    expect((await a.fetchVisionObservations('s'))['observations'], isEmpty);
    t.viewRevision = 0;
    await expectLater(
        a.fetchVisionObservations('s'), throwsA(isA<VisionLeaseException>()));
  });

  testWidgets(
      'revision: stale binding never reaches UI and current rebind recovers',
      (tester) async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final api = leaseClient(login, t);
    await api.createSession(wakeWord: 'test');
    var rev = 1, active = true, changeAfterData = true;
    t.transformSnapshot = (packet, request) {
      packet['viewRevision'] = rev;
      final binding = {
        'sessionId': 's',
        'cameraId': 'c',
        'producerId': 'producer',
        'sourceType': 'android_camera',
        'bindingId': rev == 1
            ? '00000000-0000-4000-8000-000000000002'
            : '00000000-0000-4000-8000-000000000004',
        'cameraEpoch': rev == 1
            ? '00000000-0000-4000-8000-000000000003'
            : '00000000-0000-4000-8000-000000000005',
        'bindingRevision': rev
      };
      packet['bindings'] = active ? [binding] : [];
      if (request.url.queryParameters['proofOnly'] != 'true') {
        packet['observations'] = active
            ? [
                {
                  ...binding,
                  'generation': 'g1',
                  'guidanceEligible': false,
                  'state': 'available',
                  'validForSeconds': 3.0,
                  'observedClasses': ['bus'],
                  'receivedAt': 'fixture'
                }
              ]
            : [];
        if (changeAfterData) {
          changeAfterData = false;
          rev = 2;
          active = false;
        }
      }
      return packet;
    };
    await tester.pumpWidget(MaterialApp(
        home: VisionObservationPanel(
            sessionId: 's', fetch: api.fetchVisionObservations)));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.text('버스가 감지되었습니다'), findsNothing);
    active = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('버스가 감지되었습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test('revision: wrong observation epoch cannot borrow a valid proof',
      () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final api = leaseClient(login, t);
    await api.createSession(wakeWord: 'test');
    t.transformSnapshot = (packet, request) {
      packet['viewRevision'] = 1;
      final binding = {
        'sessionId': 's',
        'cameraId': 'c',
        'producerId': 'p',
        'sourceType': 'android_camera',
        'bindingId': '00000000-0000-4000-8000-000000000002',
        'cameraEpoch': '00000000-0000-4000-8000-000000000003',
        'bindingRevision': 1
      };
      packet['bindings'] = [binding];
      if (request.url.queryParameters['proofOnly'] != 'true') {
        packet['observations'] = [
          {
            ...binding,
            'cameraEpoch': '00000000-0000-4000-8000-000000000099',
            'generation': 'g1',
            'guidanceEligible': false
          }
        ];
      }
      return packet;
    };
    await expectLater(
        api.fetchVisionObservations('s'), throwsA(isA<VisionLeaseException>()));
  });
  test('lease: duplicate clients share one login operation and receipt',
      () async {
    final login = LeaseTestLogin(), transport = LeaseTestTransport();
    final a = leaseClient(login, transport), b = leaseClient(login, transport);
    await Future.wait([a.prepareVisionLease(), b.prepareVisionLease()]);
    expect(transport.registrations, 1);
    expect(transport.issues, 1);
    await b.prepareVisionLease();
    expect(transport.issues, 1);
  });
  for (final path in [
    '/guidance/vision-lease/operations',
    '/guidance/vision-lease'
  ]) {
    test('lease: same operation recovers lost response at $path', () async {
      final login = LeaseTestLogin(),
          transport = LeaseTestTransport()..lose = path;
      final a = leaseClient(login, transport);
      await expectLater(
          a.prepareVisionLease(), throwsA(isA<VisionLeaseException>()));
      await leaseClient(login, transport).prepareVisionLease();
      final ids = transport.bodies
          .where((b) => b.containsKey('operationId'))
          .map((b) => b['operationId'])
          .toSet();
      expect(ids.length, 1);
      expect(
          transport.bodies.where((b) => b.containsKey('startTicket')).every(
              (b) => b['startTicket'] == transport.ticket!['startTicket']),
          isTrue);
    });
  }
  test('lease: 403 is terminal across clients with no new operation', () async {
    final login = LeaseTestLogin(),
        transport = LeaseTestTransport()..status = 403;
    await expectLater(leaseClient(login, transport).prepareVisionLease(),
        throwsA(isA<VisionLeaseException>()));
    transport.status = 200;
    expect(() => leaseClient(login, transport).prepareVisionLease(),
        throwsA(isA<VisionLeaseException>()));
    expect(transport.requests.length, 1);
  });
  test('lease: late old-login ticket never issues or overwrites new login',
      () async {
    final login = LeaseTestLogin(),
        transport = LeaseTestTransport()
          ..pausePath = '/guidance/vision-lease/operations'
          ..pause = Completer<void>();
    final old = leaseClient(login, transport).prepareVisionLease();
    final rejected = expectLater(old, throwsA(isA<VisionLeaseException>()));
    await Future<void>.delayed(Duration.zero);
    login.login();
    transport.pause!.complete();
    await rejected;
    expect(transport.issues, 0);
    transport.pausePath = null;
    transport.ticket = null;
    await leaseClient(login, transport).prepareVisionLease();
    expect(transport.issues, 1);
    expect(transport.bodies[0]['operationId'],
        isNot(transport.ticket!['operationId']));
  });
  test('lease: preview requires admission and includes owned lease header',
      () async {
    final login = LeaseTestLogin(),
        t = LeaseTestTransport(),
        c = leaseClient(LeaseTestLogin(), LeaseTestTransport());
    await expectLater(
        c.fetchVisionObservations('s'), throwsA(isA<VisionLeaseException>()));
    final a = leaseClient(login, t);
    await a.createSession(wakeWord: 'test');
    expect((await a.fetchVisionObservations('s'))['observations'], isEmpty);
    expect(
        t.requests
            .where((r) =>
                r.url.path.contains('observations') &&
                r.url.queryParameters['proofOnly'] != 'true')
            .single
            .headers['X-Mobi-Vision-Lease'],
        'l' * 43);
    final proofs =
        t.requests.where((r) => r.url.queryParameters['proofOnly'] == 'true');
    expect(proofs.length, 1);
    expect(proofs.single.headers['X-Mobi-Vision-Lease'], 'l' * 43);
  });
  test('lease: remote generation change fences preview without invented fields',
      () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final a = leaseClient(login, t);
    await a.createSession(wakeWord: 'test');
    t.generation = 'remote-reset';
    await expectLater(
        a.fetchVisionObservations('s'), throwsA(isA<VisionLeaseException>()));
  });
  test(
      'lease: reset invalidates pending old preview then binds fresh generation',
      () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final a = leaseClient(login, t);
    await a.createSession(wakeWord: 'test');
    t.pausePath = '/ai-vision/v2/sessions/s/observations';
    t.pause = Completer<void>();
    final pending = a.fetchVisionObservations('s');
    final rejected = expectLater(pending, throwsA(isA<VisionLeaseException>()));
    await Future<void>.delayed(Duration.zero);
    a.invalidateVisionSession('s');
    t.pause!.complete();
    await rejected;
    t.pausePath = null;
    await a.resetSession(sessionId: 's');
    expect((await a.fetchVisionObservations('s'))['observations'], isEmpty);
  });
  test('lease: logout closes all existing client sessions', () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final a = leaseClient(login, t);
    await a.createSession(wakeWord: 'test');
    await a.revokeVisionLease();
    await expectLater(leaseClient(login, t).fetchVisionObservations('s'),
        throwsA(isA<VisionLeaseException>()));
    expect(t.requests.last.method, 'DELETE');
  });
  test('lease: default ordinary Guidance sends no lease or ticket', () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final a = leaseClient(login, t, enabled: false);
    await a.createSession(wakeWord: 'test');
    expect(t.requests.length, 1);
    expect(
        t.requests.single.headers.containsKey('X-Mobi-Vision-Lease'), isFalse);
    await expectLater(
        a.fetchVisionObservations('s'), throwsA(isA<VisionLeaseException>()));
  });

  test('lease: token refresh retries the same registration operation',
      () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport()..status = 401;
    final a = V3AgentApiClient(
        baseUrl: 'http://127.0.0.1:18443',
        visionLeaseEnabled: true,
        visionLogin: login.capture,
        authClient: AuthenticatedApiClient(
            client: t,
            requestGuard: () => login.capture().isCurrent,
            tokenLoader: ({bool forceRefresh = false}) async {
              if (forceRefresh) t.status = 200;
              return 'local-test-only';
            }));
    await a.prepareVisionLease();
    expect(
        t.bodies
            .where((b) => !b.containsKey('startTicket'))
            .map((b) => b['operationId'])
            .toSet()
            .length,
        1);
    expect(
        t.requests.where((r) => r.url.path.endsWith('/operations')).length, 2);
  });
  test('lease: expired receipt admits no observation requests', () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport()..expired = true;
    final a = leaseClient(login, t);
    await expectLater(
        a.prepareVisionLease(), throwsA(isA<VisionLeaseException>()));
    await expectLater(
        a.fetchVisionObservations('s'), throwsA(isA<VisionLeaseException>()));
    expect(t.requests.any((r) => r.url.path.contains('observations')), isFalse);
  });
  test('lease: late issued receipt cannot be adopted after same UID relogin',
      () async {
    final login = LeaseTestLogin(),
        t = LeaseTestTransport()
          ..pausePath = '/guidance/vision-lease'
          ..pause = Completer<void>();
    final pending = leaseClient(login, t).prepareVisionLease();
    final denied = expectLater(pending, throwsA(isA<VisionLeaseException>()));
    while (t.requests.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    login.login();
    t.pause!.complete();
    await denied;
    final newer = leaseClient(login, t);
    await expectLater(newer.fetchVisionObservations('s'),
        throwsA(isA<VisionLeaseException>()));
    expect(t.requests.length, 2);
  });
  test('lease: trailing slash cannot create a second operation', () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    await leaseClient(login, t).prepareVisionLease();
    await leaseClient(login, t, origin: 'http://127.0.0.1:18441/')
        .prepareVisionLease();
    expect(t.registrations, 1);
    expect(t.issues, 1);
  });
  for (final status in [401, 409, 410, 422]) {
    test('lease: $status is terminal and emits no observation', () async {
      final login = LeaseTestLogin(), t = LeaseTestTransport()..status = status;
      final a = leaseClient(login, t);
      await expectLater(
          a.prepareVisionLease(), throwsA(isA<VisionLeaseException>()));
      expect(
          () => a.prepareVisionLease(), throwsA(isA<VisionLeaseException>()));
      expect(
          t.requests.any((r) => r.url.path.contains('observations')), isFalse);
    });
  }

  test('lease: old client cleanup cannot revoke a newer same UID login',
      () async {
    final login = LeaseTestLogin(), t = LeaseTestTransport();
    final a = leaseClient(login, t);
    await a.createSession(wakeWord: 'test');
    login.login();
    t.ticket = null;
    final b = leaseClient(login, t);
    await b.createSession(wakeWord: 'test');
    await expectLater(
        a.revokeVisionLease(), throwsA(isA<VisionLeaseException>()));
    expect(t.requests.where((r) => r.method == 'DELETE'), isEmpty);
    expect((await b.fetchVisionObservations('s'))['observations'], isEmpty);
  });
  test('lease: shared timeout slot cannot be bypassed by a new client',
      () async {
    final login = LeaseTestLogin(),
        t = LeaseTestTransport()
          ..pausePath = '/guidance/vision-lease/operations'
          ..pause = Completer<void>();
    final a = leaseClient(login, t, origin: 'http://127.0.0.1:18442');
    await expectLater(
        a.prepareVisionLease(), throwsA(isA<VisionLeaseException>()));
    await expectLater(
        leaseClient(login, t, origin: 'http://127.0.0.1:18442')
            .prepareVisionLease(),
        throwsA(isA<VisionLeaseException>()));
    expect(t.requests.length, 1);
    t.pause!.complete();
    await Future<void>.delayed(Duration.zero);
    t.pausePath = null;
    await a.prepareVisionLease();
    expect(t.issues, 1);
  });
}

class PhoneTestTransport extends LeaseTestTransport {
  int uploads = 0, stops = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!request.url.path.contains('/phone-camera')) return super.send(request);
    expect(request.headers['X-Mobi-Vision-Lease'], 'l' * 43);
    final binding = {
      'sessionId': 's',
      'producerId': 'owner',
      'cameraId': 'phone-owner',
      'sourceType': 'android_camera',
      'nextFrameIndex': 0,
      'bindingId': '00000000-0000-4000-8000-000000000002',
      'cameraEpoch': '00000000-0000-4000-8000-000000000003',
    };
    var status = 201;
    Map<String, dynamic> result = binding;
    if (request.url.path.endsWith('/events')) {
      uploads++;
      final body = jsonDecode((request as http.Request).body) as Map;
      expect(body['sourceType'], 'android_camera');
      expect(body['producerId'], 'owner');
      result = {
        'accepted': true,
        'guidanceEligible': false,
        'visionEventId': body['visionEventId'],
        'bindingId': binding['bindingId']
      };
      status = 202;
    } else if (request.method == 'DELETE') {
      stops++;
      status = 204;
    }
    return http.StreamedResponse(
        Stream.value(utf8.encode(status == 204 ? '' : jsonEncode(result))),
        status);
  }
}
