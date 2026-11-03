import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/pages/home_page.dart';
import 'cloud_ride_firebase_fake.dart';

void main() {
  late FirebaseAuthSession auth;
  late CloudRidePlan plan;
  late MockClient transport;
  late List<http.Request> calls;
  Completer<void>? healthDelay, responseDelay;
  int businessCount = 0, refusals = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OfflineFirebase.install();
    auth = OfflineFirebase.sessionForRole('passenger');
    plan = CloudRidePlan.offlineFixture();
    calls = [];
    healthDelay = null;
    responseDelay = null;
    businessCount = 0;
    refusals = 0;
    transport = MockClient((r) async {
      calls.add(r);
      if (r.url.path == '/health') {
        await healthDelay?.future;
        return http.Response(
            jsonEncode({
              'cloudTestProjectId': CloudRidePlan.project,
              'cloudTestRunId': plan.dataRun
            }),
            200);
      }
      businessCount++;
      await responseDelay?.future;
      if (refusals > 0) {
        refusals--;
        return http.Response('{}', 401);
      }
      return http.Response(
          jsonEncode({
            'requestId': plan.requestId,
            'status': 'WAITING',
            'targetDriverId': plan.uid('driver-502')
          }),
          200);
    });
  });
  tearDown(() async {
    transport.close();
    await OfflineFirebase.state.events.close();
  });
  Future<void> login([String suffix = 'passenger-a']) =>
      auth.signIn('$suffix@offline.test', 'offline').then((_) {});
  CloudRideBinding bind() => plan.bind(
      session: auth,
      web: testWeb('passenger'),
      role: 'passenger',
      transport: transport);
  Future<http.Response> post(CloudRideBinding b) =>
      b.authClient.post(Uri.parse('${plan.backendUrl}/ride-requests'),
          headers: {'Idempotency-Key': plan.idempotencyKey},
          body: jsonEncode({
            'userId': plan.uid('passenger-a'),
            'stopId': plan.stopId,
            'routeId': 'MOCK-502',
            'busNo': '502'
          }));
  Future<http.Response> get(CloudRideBinding b) => b.authClient
      .get(Uri.parse('${plan.backendUrl}/ride-requests/${plan.requestId}'));
  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(ready(), true);
  }

  final stale = isA<StaleAuthRequestException>();

  test('A1 same UID relogin invalidates delayed POST; new generation works',
      () async {
    await login();
    final b = bind();
    healthDelay = Completer<void>();
    final pending = expectLater(post(b), throwsA(stale));
    await until(() => calls.isNotEmpty);
    await auth.signOut();
    await login();
    healthDelay!.complete();
    await pending;
    expect(businessCount, 0);
    healthDelay = null;
    expect((await post(b)).statusCode, 200);
    expect(businessCount, 1);
  });
  test('A2 old 401 never obtains the replacement passenger token', () async {
    await login();
    final b = bind();
    refusals = 1;
    responseDelay = Completer<void>();
    final pending = expectLater(get(b), throwsA(stale));
    await until(() => businessCount == 1);
    await auth.signOut();
    await login('passenger-b');
    responseDelay!.complete();
    await pending;
    expect(businessCount, 1);
    expect(OfflineFirebase.state.refreshes, 0);
    expect(auth.currentAccount?.uid, plan.uid('passenger-b'));
  });
  test(
      'A3 generation change during refresh prevents retry and new session logout',
      () async {
    await login();
    final b = bind();
    refusals = 1;
    OfflineFirebase.state.refreshDelay = Completer<void>();
    final pending = expectLater(get(b), throwsA(stale));
    await until(() => OfflineFirebase.state.refreshes == 1);
    await auth.signOut();
    await login('passenger-b');
    OfflineFirebase.state.refreshDelay!.complete();
    await pending;
    expect(businessCount, 1);
    expect(auth.currentAccount?.uid, plan.uid('passenger-b'));
    expect(OfflineFirebase.state.signOuts, 1);
  });
  test('A4 different UID cannot resume health-delayed request', () async {
    await login();
    final b = bind();
    healthDelay = Completer<void>();
    final pending = expectLater(get(b), throwsA(stale));
    await until(() => calls.isNotEmpty);
    await auth.signOut();
    await login('passenger-b');
    healthDelay!.complete();
    await pending;
    expect(businessCount, 0);
    expect(auth.currentAccount?.uid, plan.uid('passenger-b'));
  });
  test('A5 old unauthorized callback cannot sign out replacement driver',
      () async {
    await login();
    final b = bind();
    refusals = 1;
    responseDelay = Completer<void>();
    final pending = expectLater(get(b), throwsA(stale));
    await until(() => businessCount == 1);
    await auth.signOut();
    await login('driver-a');
    responseDelay!.complete();
    await pending;
    expect(auth.currentAccount?.uid, plan.uid('driver-a'));
    expect(OfflineFirebase.state.signOuts, 1);
  });
  test('A6 current generation refresh succeeds once, expiry still signs out',
      () async {
    await login();
    final b = bind();
    refusals = 1;
    expect((await get(b)).statusCode, 200);
    expect(OfflineFirebase.state.refreshes, 1);
    expect(OfflineFirebase.state.signOuts, 0);
    refusals = 2;
    await expectLater(
        get(b),
        throwsA(isA<AuthenticatedApiException>()
            .having((e) => e.statusCode, 'status', 401)));
    expect(auth.currentAccount, isNull);
    expect(OfflineFirebase.state.signOuts, 1);
  });
  test('started signOut is serialized before a later signIn', () async {
    await login();
    OfflineFirebase.state.signOutDelay = Completer<void>();
    final out = auth.signOut();
    await until(() => OfflineFirebase.state.signOuts == 1);
    final next = login('passenger-b');
    await Future<void>.delayed(Duration.zero);
    expect(OfflineFirebase.state.signIns, 1);
    expect(auth.currentAccount, isNull);
    OfflineFirebase.state.signOutDelay!.complete();
    await out;
    await next;
    expect(auth.currentAccount?.uid, plan.uid('passenger-b'));
  });
  testWidgets('old response after relogin cannot populate the new HomePage',
      (t) async {
    await login();
    final b = bind();
    await t.pumpWidget(MaterialApp(
        home: AuthGate(
            configurationReady: true,
            session: auth,
            requiredRole: 'passenger',
            builder: (_, account) => HomePage.cloudVerification(
                binding: b,
                agentName: '모비',
                onEditAgentName: () {},
                onReturnToModeSelection: () {}))));
    await t.pumpAndSettle();
    responseDelay = Completer<void>();
    final button = find.text('탑승 요청하기');
    await t.ensureVisible(button);
    await t.tap(button);
    await t.pump();
    expect(businessCount,
        1); // Already sent: remote work is not claimed cancelled.
    await auth.signOut();
    await login();
    await t.pumpAndSettle();
    responseDelay!.complete();
    await t.pumpAndSettle();
    expect(find.text('WAITING'), findsNothing);
    expect(find.text('요청 전'), findsOneWidget);
    expect(businessCount, 1);
    await t.pumpWidget(const SizedBox());
  });
}
