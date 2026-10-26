import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/pages/home_page.dart';
import 'package:mobi_passenger_app/src/pages/ride_request_panel.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ride_business_flow_test.dart' show Session;

void main() {
  late Session auth;
  late MockClient transport;
  late BackendApiClient api;
  late List<http.Request> requests;
  var failBus = false;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    auth = Session('passenger-a');
    requests = [];
    failBus = false;
    transport = MockClient((r) async {
      requests.add(r);
      if (r.url.path == '/health') return http.Response('{}', 200);
      if (r.url.path == '/bus-info/stops/mock-stop-001/arrivals') {
        if (failBus) return http.Response('{}', 503);
        return http.Response(
            jsonEncode({
              'stopId': 'mock-stop-001',
              'arrivals': [
                {
                  'routeId': 'OFFLINE-502',
                  'busNo': '502',
                  'arrivalMinutes': 2,
                  'remainingStops': 1,
                  'lowFloor': true,
                  'congestion': 'NORMAL',
                  'updatedAt': '2026-10-26T00:00:00Z'
                }
              ]
            }),
            200);
      }
      if (r.url.path == '/ride-requests') {
        expect(jsonDecode(r.body)['userId'], auth.currentAccount!.uid);
        return http.Response(
            jsonEncode({
              'requestId': 'home-request-1',
              'targetDriverId': 'driver-502',
              'status': 'WAITING'
            }),
            200);
      }
      // Startup preservation test: a real POST path is attempted through Mock,
      // returning failure, never inventing a successful guidance session.
      if (r.url.path == '/guidance/session') return http.Response('{}', 503);
      throw StateError(
          'Unapproved HomePage request: ${r.method} ${r.url.path}');
    });
    api = BackendApiClient(
        baseUrl: 'http://127.0.0.1:8193',
        useMockData: false,
        publicClient: transport,
        authClient: AuthenticatedApiClient(
            client: transport,
            tokenLoader: auth.getIdToken,
            onUnauthorized: auth.signOut));
  });
  tearDown(() async {
    transport.close();
    await auth.events.close();
  });
  Widget home({BackendApiClient? backend}) => MaterialApp(
      home: HomePage.testHarness(
          agentName: '모비',
          dataMode: 'mock',
          onEditAgentName: () {},
          onReturnToModeSelection: () {},
          api: backend ?? api,
          auth: auth));

  testWidgets(
      'whole HomePage startup performs only health/bus GET and disables voice routes',
      (tester) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.text('MOBI 탑승객 데모'), findsOneWidget);
    expect(find.byType(RideRequestPanel), findsOneWidget);
    expect(
        requests.map((r) => '${r.method} ${r.url.path}').toList(),
        containsAll(
            ['GET /health', 'GET /bus-info/stops/mock-stop-001/arrivals']));
    expect(requests.length, 2);
    for (final label in ['모비 버스 탑승 보조 열기', '음성으로 목적지 입력', '현재 상태 음성 안내']) {
      final button = tester.widget<ButtonStyleButton>(find
          .ancestor(
              of: find.text(label),
              matching: find.bySubtype<ButtonStyleButton>())
          .first);
      expect(button.onPressed, isNull, reason: label);
    }
    for (final label in ['V3 버스 탑승 보조 화면 열기', '음성으로 목적지 입력', '현재 상태 음성 안내']) {
      final semantics = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .singleWhere((s) => s.properties.label == label);
      expect(semantics.properties.enabled, isFalse,
          reason: 'Disabled accessibility state: $label');
    }
    expect(find.text('오프라인 업무 검증 · 음성 비활성'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('whole HomePage derives draft from selected bus and injected UID',
      (tester) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('탑승 요청하기'));
    await tester.tap(find.text('탑승 요청하기'));
    await tester.pumpAndSettle();
    expect(find.text('WAITING'), findsOneWidget);
    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(post.url.path, '/ride-requests');
    expect(jsonDecode(post.body), {
      'userId': 'passenger-a',
      'stopId': 'mock-stop-001',
      'routeId': 'OFFLINE-502',
      'busNo': '502'
    });
    expect(requests.any((r) => r.url.path.contains('guidance')), isFalse);
  });
  test(
      'V3 client preserves startup POST contract without a real guidance session',
      () async {
    final voice = V3AgentApiClient(
        baseUrl: 'http://127.0.0.1:8193',
        authClient: AuthenticatedApiClient(
            client: transport, tokenLoader: auth.getIdToken));
    await expectLater(
        voice.createSession(wakeWord: '모비'), throwsA(isA<V3ApiException>()));
    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(post.url.path, '/guidance/session');
    expect(jsonDecode(post.body), {'wakeWord': '모비'});
  });
  testWidgets('bus failure stays visible and request cannot be created',
      (tester) async {
    failBus = true;
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.textContaining('503 상태 코드'), findsOneWidget);
    await tester.ensureVisible(find.text('탑승 요청하기'));
    await tester.tap(find.text('탑승 요청하기'));
    await tester.pumpAndSettle();
    expect(requests.any((r) => r.method == 'POST'), isFalse);
  });
  testWidgets(
      'non-loopback test dependencies fail before network and dispose safely',
      (tester) async {
    final bad = BackendApiClient(
        baseUrl: 'https://example.test',
        publicClient: transport,
        authClient: AuthenticatedApiClient(
            client: transport, tokenLoader: auth.getIdToken));
    await tester.pumpWidget(home(backend: bad));
    expect(tester.takeException(), isA<StateError>());
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets('reentry repeats only read-only initialization, never guidance',
      (tester) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.url.path == '/health').length, 2);
    expect(requests.where((r) => r.url.path.contains('/arrivals')).length, 2);
    expect(requests.any((r) => r.method == 'POST'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
