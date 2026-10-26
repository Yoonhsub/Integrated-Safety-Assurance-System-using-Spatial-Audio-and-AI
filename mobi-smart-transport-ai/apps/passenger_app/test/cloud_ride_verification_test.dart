import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/pages/home_page.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart';
import 'package:mobi_passenger_app/src/services/cloud_ride_intent.dart';
import 'package:mobi_passenger_app/cloud_ride_verification_main.dart'
    as passenger_entry;
// ignore: avoid_relative_lib_imports
import '../../driver_app/lib/cloud_ride_verification_main.dart' as driver_entry;
// ignore: avoid_relative_lib_imports
import '../../driver_app/lib/src/pages/home_page.dart' as driver;
// ignore: avoid_relative_lib_imports
import '../../driver_app/lib/src/services/backend_api_client.dart'
    as driver_api;
import 'cloud_ride_firebase_fake.dart';

void main() {
  late CloudRidePlan plan;
  late FirebaseAuthSession session;
  late MockClient transport;
  late List<http.Request> calls;
  Map<String, dynamic>? record;
  int failures = 0, failureCode = 401;
  bool wrongHealth = false, networkFailure = false;
  Completer<void>? healthDelay;
  Completer<void>? postDelay;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OfflineFirebase.install();
    plan = CloudRidePlan.offlineFixture();
    session = FirebaseAuthSession.instance;
    calls = [];
    record = null;
    failures = 0;
    failureCode = 401;
    wrongHealth = false;
    networkFailure = false;
    healthDelay = null;
    postDelay = null;
    transport = MockClient((r) async {
      calls.add(r);
      expect(r.url.origin, plan.backendUrl);
      if (r.url.path == '/health') {
        await healthDelay?.future;
        return http.Response(
            jsonEncode({
              'cloudTestProjectId': CloudRidePlan.project,
              'cloudTestRunId': wrongHealth ? 'wrong-run' : plan.dataRun
            }),
            200);
      }
      expect(r.headers['Authorization'], startsWith('Bearer offline|'));
      if (networkFailure) throw http.ClientException('offline failure');
      if (failures > 0) {
        failures--;
        return http.Response('{}', failureCode);
      }
      final caller = r.headers['Authorization']!.split('|')[1];
      if (r.method == 'POST') {
        await postDelay?.future;
        expect(r.url.path, '/ride-requests');
        expect(r.headers['Idempotency-Key'], plan.idempotencyKey);
        plan.validateDraft(
            Map<String, Object?>.from(jsonDecode(r.body) as Map));
        record ??= {
          ...jsonDecode(r.body) as Map<String, dynamic>,
          'requestId': plan.requestId,
          'targetDriverId': plan.uid('driver-502'),
          'status': 'WAITING',
          'createdAt': '2026-10-26T00:00:00Z',
          'updatedAt': null
        };
      } else if (r.url.path.startsWith('/drivers/')) {
        expect(r.method, 'GET');
        return http.Response(
            jsonEncode({
              'requests': [
                if (record != null && caller == plan.uid('driver-a')) record,
              ]
            }),
            200);
      } else {
        expect(r.url.path.startsWith('/ride-requests/${plan.requestId}'), true);
        if (caller != plan.uid('passenger-a') &&
            caller != plan.uid('driver-a')) {
          return http.Response('{}', 403);
        }
        if (r.method == 'PATCH') {
          final next = jsonDecode(r.body)['status'];
          if (record!['status'] == 'CANCELLED') return http.Response('{}', 409);
          record!['status'] = next;
        }
      }
      return http.Response(jsonEncode(record ?? {}), 200);
    });
  });
  tearDown(() async {
    transport.close();
    await OfflineFirebase.state.events.close();
  });
  Future<CloudRideBinding> binding([String suffix = 'passenger-a']) async {
    await session.signIn('$suffix@offline.test', 'offline-input-only');
    return plan.bind(
        session: OfflineFirebase.sessionForRole(OfflineFirebase.state.role),
        web: testWeb(OfflineFirebase.state.role),
        role: OfflineFirebase.state.role,
        transport: transport);
  }

  Future<void> home(WidgetTester t, CloudRideBinding b) async {
    await t.pumpWidget(MaterialApp(
        home: AuthGate(
            configurationReady: true,
            requiredRole: 'passenger',
            session: b.session,
            builder: (_, account) => HomePage.cloudVerification(
                key: UniqueKey(),
                binding: b,
                agentName: '모비',
                onEditAgentName: () {},
                onReturnToModeSelection: () {}))));
    await t.pumpAndSettle();
  }

  Future<void> click(WidgetTester t, String label) async {
    await t.ensureVisible(find.text(label));
    await t.tap(find.text(label));
    await t.pumpAndSettle();
  }

  BackendApiClient api(CloudRideBinding b) => BackendApiClient(
      baseUrl: plan.backendUrl,
      useMockData: false,
      publicClient: b.publicClient,
      authClient: b.authClient);

  test(
      'offline fixture matches the Backend JSON contract and cannot be a cloud registration',
      () {
    final data = jsonDecode(
        File('../../shared/contracts/fixtures/cloud_ride_ui_offline.json')
            .readAsStringSync());
    expect(plan.dataRun, data['dataRunId']);
    expect(plan.requestId, data['requestId']);
    expect(plan.idempotencyKey, data['idempotencyKey']);
    expect(plan.stopId, data['stopId']);
    expect(() => CloudRidePlan.fromEnvironment(role: 'passenger'),
        throwsStateError);
  });
  test('project/app crossover is rejected before transport', () async {
    await binding();
    expect(
        () => plan.bind(
            session: session,
            web: testWeb('driver'),
            role: 'passenger',
            transport: transport),
        throwsStateError);
    expect(
        () => plan.bind(
            session: OfflineFirebase.sessionForRole('wrong'),
            web: testWeb('passenger'),
            role: 'passenger',
            transport: transport),
        throwsStateError);
    expect(calls, isEmpty);
  });
  test(
      'only bus GET is local; unexpected stop and external/V3/FCM requests fail closed',
      () async {
    final b = await binding();
    final bus = await b.publicClient.get(
        Uri.parse('${plan.backendUrl}/bus-info/stops/mock-stop-001/arrivals'));
    expect(jsonDecode(bus.body)['stopId'], plan.stopId);
    expect(calls, isEmpty);
    for (final path in [
      '/bus-info/stops/other/arrivals',
      '/guidance/session',
      '/agent/tts',
      '/notifications/send'
    ]) {
      await expectLater(
          b.publicClient.get(Uri.parse('${plan.backendUrl}$path')),
          throwsA(isA<AuthenticatedApiException>()));
    }
    await expectLater(
        b.authClient.get(Uri.parse('https://example.test/ride-requests')),
        throwsA(isA<AuthenticatedApiException>()));
    expect(calls, isEmpty);
  });
  test('wrong run claims or driver mapping sends no business request',
      () async {
    final b = await binding();
    OfflineFirebase.state.run = 'other';
    await expectLater(b.token(), throwsA(isA<AuthenticatedApiException>()));
    OfflineFirebase.state.run = CloudRidePlan.authRun;
    final d = await binding('driver-a');
    OfflineFirebase.state.driver = plan.uid('driver-105');
    await expectLater(d.token(), throwsA(isA<AuthenticatedApiException>()));
    expect(calls, isEmpty);
  });
  test('wrong Backend data run stops before POST', () async {
    final b = await binding();
    wrongHealth = true;
    await expectLater(
        b.authClient.post(Uri.parse('${plan.backendUrl}/ride-requests'),
            headers: {'Idempotency-Key': plan.idempotencyKey},
            body: jsonEncode({
              'userId': plan.uid('passenger-a'),
              'stopId': plan.stopId,
              'routeId': 'MOCK-502',
              'busNo': '502'
            })),
        throwsA(isA<AuthenticatedApiException>()));
    expect(
        calls.every((r) => r.method == 'GET' && r.url.path == '/health'), true);
  });
  test('unreviewed random key and DTO are rejected before I/O', () async {
    final b = await binding();
    await expectLater(
        b.authClient.post(Uri.parse('${plan.backendUrl}/ride-requests'),
            headers: {'Idempotency-Key': 'random'}, body: '{}'),
        throwsA(isA<AuthenticatedApiException>()));
    await expectLater(
        CloudRideIntentStore(plan).begin(RideRequestDraft(
            userId: plan.uid('passenger-a'),
            stopId: 'mock-stop-001',
            routeId: 'MOCK-502',
            busNo: '502')),
        throwsA(isA<AuthenticatedApiException>()));
    expect(calls, isEmpty);
  });
  testWidgets(
      'OFFLINE real FirebaseAuthSession + HomePage + Driver UI WAITING ACCEPTED CANCELLED',
      (t) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final p = await binding();
    expect(p.session, isA<FirebaseAuthSession>());
    await home(t, p);
    expect(find.text('Firebase 업무 검증 · V3/음성 비활성'), findsOneWidget);
    await click(t, '탑승 요청하기');
    expect(find.text('WAITING'), findsOneWidget,
        reason:
            '${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList()} / ${calls.map((r) => '${r.method} ${r.url.path}').toList()}');
    final d = await binding('driver-a');
    await t.pumpWidget(MaterialApp(
        home: driver.HomePage(
            key: UniqueKey(),
            session: session,
            apiClient: driver_api.BackendApiClient(
                baseUrl: plan.backendUrl,
                useMockData: false,
                publicClient: d.publicClient,
                authClient: d.authClient))));
    await t.pumpAndSettle();
    await click(t, '요청 수락');
    expect(record!['status'], 'ACCEPTED');
    await binding();
    await home(t, p);
    expect(find.text('ACCEPTED'), findsOneWidget);
    await click(t, '내 탑승 요청 취소');
    expect(find.text('CANCELLED'), findsOneWidget);
    await session.signOut();
    await t.pumpAndSettle();
    expect(find.text('CANCELLED'), findsNothing);
    expect(find.widgetWithText(FilledButton, '로그인'), findsOneWidget);
    await binding();
    await home(t, p);
    expect(find.text('CANCELLED'), findsOneWidget);
    await binding('passenger-b');
    await home(t, p);
    expect(find.text('요청 전'), findsOneWidget);
    expect(find.text('CANCELLED'), findsNothing);
    await click(t, '탑승 요청하기');
    expect(find.text(const AuthenticatedApiException(403).userMessage),
        findsOneWidget);
    expect(calls.where((r) => r.method == 'POST').length, 1);
    expect(
        calls.any((r) =>
            r.url.path.contains('guidance') || r.url.path.contains('bus-info')),
        false);
    expect(OfflineFirebase.state.signIns, greaterThanOrEqualTo(4));
    await t.pumpWidget(const SizedBox());
  });
  test('401 refreshes once and clears real session on repeated refusal',
      () async {
    final b = await binding();
    failures = 2;
    await expectLater(
        b.authClient.get(
            Uri.parse('${plan.backendUrl}/ride-requests/${plan.requestId}')),
        throwsA(isA<AuthenticatedApiException>()));
    expect(OfflineFirebase.state.refreshes, 1);
    expect(session.currentAccount, isNull);
  });
  for (final status in [403, 409]) {
    test('HTTP $status is preserved by guarded transport', () async {
      final b = await binding();
      failures = 1;
      failureCode = status;
      if (status == 403) {
        await expectLater(
            b.authClient.get(Uri.parse(
                '${plan.backendUrl}/ride-requests/${plan.requestId}')),
            throwsA(isA<AuthenticatedApiException>()
                .having((e) => e.statusCode, 'status', 403)));
      } else {
        expect(
            (await b.authClient.get(Uri.parse(
                    '${plan.backendUrl}/ride-requests/${plan.requestId}')))
                .statusCode,
            409);
      }
    });
  }
  test('account switch during health delay cannot send old bearer', () async {
    final b = await binding();
    healthDelay = Completer<void>();
    final pending = b.authClient
        .get(Uri.parse('${plan.backendUrl}/ride-requests/${plan.requestId}'));
    final checked =
        expectLater(pending, throwsA(isA<AuthenticatedApiException>()));
    while (calls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await session.signOut();
    healthDelay!.complete();
    await checked;
    expect(calls.length, 1);
    expect(calls.single.url.path, '/health');
  });
  test('network failure is not a synthetic successful response', () async {
    final b = await binding();
    networkFailure = true;
    final result =
        await api(b).fetchRideRequestStatus(requestId: plan.requestId);
    expect(result.statusLabel, isNot('WAITING'));
  });
  testWidgets(
      'delayed double click sends one reviewed POST and remount restores it',
      (t) async {
    final b = await binding();
    await home(t, b);
    postDelay = Completer<void>();
    final button = find.text('탑승 요청하기');
    await t.ensureVisible(button);
    final position = t.getCenter(button);
    await t.tapAt(position);
    await t.pump();
    await t.tapAt(position);
    await t.pump();
    expect(calls.where((r) => r.method == 'POST').length, 1);
    postDelay!.complete();
    await t.pumpAndSettle();
    expect(find.text('WAITING'), findsOneWidget);
    await home(t, b);
    expect(find.text('WAITING'), findsOneWidget);
    expect(calls.where((r) => r.method == 'POST').length, 1);
  });
  testWidgets('unregistered verification targets fail before Firebase login',
      (t) async {
    await passenger_entry.main();
    await t.pumpAndSettle();
    expect(find.textContaining('실행 계획이 없어 차단'), findsOneWidget);
    await driver_entry.main();
    await t.pumpAndSettle();
    expect(find.textContaining('실행 계획이 없어 차단'), findsOneWidget);
    expect(OfflineFirebase.state.signIns, 0);
    expect(calls, isEmpty);
  });
  test(
      'data-run recovery refuses a foreign ID and stable key rejects passenger B',
      () async {
    final store = CloudRideIntentStore(plan);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'mobi.cloud.ride.${plan.dataRun}.active.${plan.uid('passenger-a')}',
        'foreign-id');
    await expectLater(
        store.activeRequest(plan.uid('passenger-a')), throwsStateError);
    await expectLater(
        store.begin(RideRequestDraft(
            userId: plan.uid('passenger-b'),
            stopId: plan.stopId,
            routeId: 'MOCK-502',
            busNo: '502')),
        throwsA(isA<AuthenticatedApiException>()));
  });
}
