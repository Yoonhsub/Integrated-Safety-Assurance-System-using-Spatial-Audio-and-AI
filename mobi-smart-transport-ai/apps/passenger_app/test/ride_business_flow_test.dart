import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobi_passenger_app/src/pages/ride_request_panel.dart';
import 'package:mobi_passenger_app/src/services/backend_api_client.dart'
    as passenger;
import 'package:mobi_passenger_app/src/services/ride_creation_intent.dart';
// Same-repository integration deliberately exercises the actual other app.
// ignore: avoid_relative_lib_imports
import '../../driver_app/lib/src/pages/home_page.dart' as driver;
// Same-repository integration deliberately exercises the actual other app.
// ignore: avoid_relative_lib_imports
import '../../driver_app/lib/src/services/backend_api_client.dart'
    as driver_api;

// No Firebase SDK, credentials, sockets or cloud requests. The same actual HTTP
// clients and business Widgets consume the Backend RideRequestRecord contract.
class Session implements AuthSession {
  Session(String uid) : account = AuthAccount(uid: uid);
  AuthAccount? account;
  final events = StreamController<AuthAccount?>.broadcast(sync: true);
  @override
  AuthAccount? get currentAccount => account;
  @override
  Stream<AuthAccount?> get authStateChanges => events.stream;
  void switchTo(String? uid) {
    account = uid == null ? null : AuthAccount(uid: uid);
    events.add(account);
  }

  @override
  Future<AuthAccount> signIn(String email, String password) async {
    switchTo(email.split('@').first);
    return account!;
  }

  @override
  Future<void> signOut() async => switchTo(null);
  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async => account?.uid;
  @override
  Future<Object?> getCustomClaim(String name,
          {bool forceRefresh = false}) async =>
      name == 'mobi_driver_id' ? '${account?.uid}-502' : 'driver';
}

class ContractServer {
  Map<String, dynamic>? record;
  final requests = <http.Request>[];
  final unexpected = <String>[];
  int? failStatus;
  bool networkFailure = false;
  Completer<void>? delay;
  int get posts => requests.where((r) => r.method == 'POST').length;
  int get patches => requests.where((r) => r.method == 'PATCH').length;

  Future<http.Response> handle(http.Request request) async {
    if (request.url.host != 'offline.test') {
      unexpected.add(request.url.toString());
    }
    expect(request.url.host, 'offline.test');
    final path = request.url.path;
    if (!{
          '/health',
          '/ride-requests',
          '/ride-requests/request-1',
          '/ride-requests/request-1/status',
          '/drivers/driver-a-502/ride-requests',
          '/drivers/driver-b-502/ride-requests'
        }.contains(path) ||
        !{'GET', 'POST', 'PATCH'}.contains(request.method)) {
      unexpected.add('${request.method} $path');
    }
    // Explicit allowlist: accidental RTDB, FCM, Guidance or other API fails.
    expect({
      '/health',
      '/ride-requests',
      '/ride-requests/request-1',
      '/ride-requests/request-1/status',
      '/drivers/driver-a-502/ride-requests',
      '/drivers/driver-b-502/ride-requests'
    }, contains(path));
    requests.add(request);
    if (path == '/health') return http.Response('{}', 200);
    final caller =
        request.headers['authorization']?.replaceFirst('Bearer ', '');
    if (delay != null) await delay!.future;
    if (networkFailure) throw http.ClientException('offline network failure');
    if (failStatus != null) return http.Response('{}', failStatus!);
    if (caller == null || caller == 'invalid') return http.Response('{}', 401);
    if (request.method == 'POST') {
      final draft = jsonDecode(request.body) as Map<String, dynamic>;
      if (draft['userId'] != caller) return http.Response('{}', 403);
      expect(request.headers['Idempotency-Key'], isNotEmpty);
      record ??= {
        ...draft,
        'requestId': 'request-1',
        'targetDriverId': 'driver-a-502',
        'status': 'WAITING',
        'createdAt': '2026-10-26T00:00:00Z',
        'updatedAt': null
      };
      return http.Response(jsonEncode(record), 200);
    }
    if (path.startsWith('/drivers/')) {
      final driverId = path.split('/')[2];
      if (driverId != '$caller-502') return http.Response('{}', 403);
      return http.Response(
          jsonEncode({
            'driverId': driverId,
            'requests': [
              if (record != null && record!['targetDriverId'] == driverId)
                record,
            ]
          }),
          200);
    }
    if (record == null) return http.Response('{}', 404);
    if (caller != record!['userId'] &&
        '$caller-502' != record!['targetDriverId']) {
      return http.Response('{}', 403);
    }
    if (request.method == 'PATCH') {
      final next = jsonDecode(request.body)['status'];
      if (caller == record!['userId'] && next != 'CANCELLED') {
        return http.Response('{}', 403);
      }
      final transitions = {
        'WAITING': ['ACCEPTED', 'CANCELLED'],
        'ACCEPTED': ['ARRIVED', 'COMPLETED', 'CANCELLED'],
        'CANCELLED': <String>[]
      };
      if (!(transitions[record!['status']] ?? []).contains(next)) {
        return http.Response('{}', 409);
      }
      record!['status'] = next;
      record!['updatedAt'] = '2026-10-26T00:01:00Z';
    }
    return http.Response(jsonEncode(record), 200);
  }
}

void main() {
  late ContractServer server;
  late Session session;
  late MockClient transport;
  late passenger.BackendApiClient passengerApi;
  late driver_api.BackendApiClient driverApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = ContractServer();
    session = Session('passenger-a');
    transport = MockClient(server.handle);
    final auth = AuthenticatedApiClient(
        tokenLoader: session.getIdToken,
        onUnauthorized: session.signOut,
        client: transport);
    passengerApi = passenger.BackendApiClient(
        baseUrl: 'http://offline.test', useMockData: false, authClient: auth);
    driverApi = driver_api.BackendApiClient(
        baseUrl: 'http://offline.test',
        useMockData: false,
        authClient: auth,
        publicClient: transport);
  });
  tearDown(() async {
    expect(server.unexpected, isEmpty);
    await session.events.close();
    transport.close();
  });

  Future<void> showPassenger(WidgetTester tester) async {
    final uid = session.currentAccount?.uid ?? '';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: RideRequestPanel(
                    api: passengerApi,
                    session: session,
                    draft: passenger.RideRequestDraft(
                        userId: uid,
                        stopId: 'stop-1',
                        routeId: 'route-502',
                        busNo: '502'))))));
    await tester.pumpAndSettle();
  }

  Future<void> click(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> create(WidgetTester tester) async {
    await showPassenger(tester);
    await click(tester, '탑승 요청하기');
    expect(server.record!['status'], 'WAITING');
  }

  Future<void> showDriver(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: driver.HomePage(
            key: UniqueKey(), apiClient: driverApi, session: session)));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'OFFLINE_UI_E2E create -> driver list -> accept -> passenger restore -> cancel',
      (tester) async {
    await create(tester);
    expect(find.text('WAITING'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.switchTo('driver-a');
    await showDriver(tester);
    expect(find.text('WAITING'), findsOneWidget);
    await click(tester, '요청 수락');
    expect(server.record!['status'], 'ACCEPTED');
    expect(find.text('ACCEPTED'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    session.switchTo('passenger-a');
    await showPassenger(tester);
    expect(find.text('ACCEPTED'), findsOneWidget);
    await click(tester, '내 탑승 요청 취소');
    expect(server.record!['status'], 'CANCELLED');
    expect(find.text('CANCELLED'), findsOneWidget);
    expect(server.posts, 1);
    expect(server.patches, 2);
  });

  testWidgets('stale queued auth event cannot restore another account request',
      (tester) async {
    await create(tester);
    session.switchTo('passenger-b');
    await tester.pumpAndSettle();
    session.events.add(const AuthAccount(uid: 'passenger-a'));
    await tester.pumpAndSettle();
    expect(find.textContaining('요청 ID:'), findsNothing);
    expect(server.requests.where((r) => r.method == 'GET'), isEmpty);
    session.switchTo('passenger-a');
    await tester.pumpAndSettle();
    expect(find.text('WAITING'), findsOneWidget);
  });
  for (final status in [401, 403]) {
    testWidgets('HTTP $status is an auth/permission error, not a network error',
        (tester) async {
      server.failStatus = status;
      await showPassenger(tester);
      await click(tester, '탑승 요청하기');
      if (status == 401) {
        expect(session.currentAccount, isNull);
        expect(find.textContaining('요청 ID:'), findsNothing);
      } else {
        expect(find.textContaining('권한이 없습니다'), findsOneWidget);
      }
      expect(server.record, isNull);
    });
  }
  testWidgets(
      'cancel 409 refetches latest status without claiming cancellation',
      (tester) async {
    await create(tester);
    server.record!['status'] = 'COMPLETED';
    await click(tester, '내 탑승 요청 취소');
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(find.textContaining('요청 상태가 변경되었습니다'), findsOneWidget);
    expect(server.record!['status'], 'COMPLETED');
  });
  testWidgets('network failure is visible and retry keeps the idempotency key',
      (tester) async {
    server.networkFailure = true;
    await showPassenger(tester);
    await click(tester, '탑승 요청하기');
    expect(find.textContaining('연결할 수 없습니다'), findsOneWidget);
    server.networkFailure = false;
    await click(tester, '탑승 요청하기');
    final posts = server.requests.where((r) => r.method == 'POST').toList();
    expect(posts[0].headers['Idempotency-Key'],
        posts[1].headers['Idempotency-Key']);
    expect(server.record, isNotNull);
  });
  testWidgets(
      'delayed double create sends one POST and ignores response after logout',
      (tester) async {
    await showPassenger(tester);
    server.delay = Completer<void>();
    await tester.tap(find.text('탑승 요청하기'));
    await tester.pump();
    await tester.tap(find.text('탑승 요청하기'));
    await tester.pump();
    expect(server.posts, 1);
    session.switchTo(null);
    await tester.pump();
    server.delay!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('요청 ID:'), findsNothing);
    expect(
        await RideCreationIntentStore().activeRequest('passenger-a'), isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'restored ID is UID-scoped; another passenger sees no previous request',
      (tester) async {
    await create(tester);
    session.switchTo('passenger-b');
    await tester.pumpAndSettle();
    expect(find.textContaining('요청 ID:'), findsNothing);
    expect(server.requests.where((r) => r.method == 'GET'), isEmpty);
    session.switchTo('passenger-a');
    await tester.pumpAndSettle();
    expect(find.text('WAITING'), findsOneWidget);
  });
  testWidgets('driver 409 refetches current list and disables stale acceptance',
      (tester) async {
    await create(tester);
    await tester.pumpWidget(const SizedBox());
    session.switchTo('driver-a');
    await showDriver(tester);
    server.record!['status'] = 'CANCELLED';
    await click(tester, '요청 수락');
    expect(find.text('CANCELLED'), findsOneWidget);
    expect(find.textContaining('최신 목록'), findsWidgets);
    expect(server.patches, 1);
  });
  testWidgets(
      'driver delayed duplicate click and account change hide previous response',
      (tester) async {
    await create(tester);
    await tester.pumpWidget(const SizedBox());
    session.switchTo('driver-a');
    await showDriver(tester);
    server.delay = Completer<void>();
    await tester.tap(find.text('요청 수락'));
    await tester.pump();
    await tester.tap(find.text('처리 중...'));
    await tester.pump();
    expect(server.patches, 1);
    session.switchTo('driver-b');
    await tester.pump();
    server.delay!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('탑승 요청 request-1'), findsNothing);
    expect(find.text('요청 수락'), findsNothing);
  });
  for (final status in [401, 403]) {
    testWidgets('driver HTTP $status shows denial without exposing requests',
        (tester) async {
      session.switchTo('driver-a');
      server.failStatus = status;
      await showDriver(tester);
      expect(find.text('요청 수락'), findsNothing);
      if (status == 401) {
        expect(session.currentAccount, isNull);
      } else {
        expect(find.textContaining('권한이 없습니다'), findsOneWidget);
      }
    });
  }
  testWidgets(
      'explicit passenger refresh observes acceptance and remount preserves cancellation',
      (tester) async {
    await create(tester);
    server.record!['status'] = 'ACCEPTED';
    await click(tester, '상태 조회');
    expect(find.text('ACCEPTED'), findsOneWidget);
    await click(tester, '내 탑승 요청 취소');
    await tester.pumpWidget(const SizedBox());
    await showPassenger(tester);
    expect(find.text('CANCELLED'), findsOneWidget);
    expect(server.posts, 1);
  });
  testWidgets(
      'dispose during delayed response causes no widget update exception',
      (tester) async {
    await showPassenger(tester);
    server.delay = Completer<void>();
    await tester.tap(find.text('탑승 요청하기'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    server.delay!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('driver network failure is visible and refresh recovers',
      (tester) async {
    session.switchTo('driver-a');
    server.networkFailure = true;
    await showDriver(tester);
    expect(find.textContaining('연결할 수 없습니다'), findsOneWidget);
    server.networkFailure = false;
    await click(tester, '요청 목록 새로고침');
    expect(find.text('요청 없음'), findsWidgets);
  });
  test(
      'contract denies foreign users with 403 and terminal transition with 409',
      () async {
    await passengerApi.createRideRequest(
        draft: const passenger.RideRequestDraft(
            userId: 'passenger-a',
            stopId: 'stop-1',
            routeId: 'route-502',
            busNo: '502'),
        idempotencyKey: 'key-1');
    for (final uid in ['passenger-b', 'driver-b']) {
      session.switchTo(uid);
      final result =
          await passengerApi.fetchRideRequestStatus(requestId: 'request-1');
      expect(result.httpStatus, 403);
      expect(result.isSuccess, isFalse);
    }
    session.switchTo('driver-a');
    server.record!['status'] = 'CANCELLED';
    final result = await driverApi.updateRideRequestStatus(
        requestId: 'request-1', status: 'ACCEPTED');
    expect(result.httpStatus, 409);
    expect(result.isSuccess, isFalse);
  });
}
