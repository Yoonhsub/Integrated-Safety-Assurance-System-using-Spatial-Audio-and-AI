import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

const run = 'auth-20261023-919e07bd';
const preview = AuthOnlyConfiguration(
    enabled: true, projectId: 'mobi-auth-cloud-test', runId: run);

class FakeSession implements AuthSession {
  FakeSession({String? uid, Map<String, Object?>? claims})
      : claims = claims ?? {} {
    account =
        uid == null ? null : AuthAccount(uid: uid, email: '$uid@example.test');
  }
  final controller = StreamController<AuthAccount?>.broadcast(sync: true);
  AuthAccount? account;
  Map<String, Object?> claims;
  final roleQueue = <Future<Object?>>[];
  int claimCalls = 0;
  int tokenCalls = 0;
  bool failClaims = false;
  bool failSignOut = false;
  bool emitSignOutEvent = true;
  Completer<void>? pendingSignOut;

  void emit(String? uid) {
    account =
        uid == null ? null : AuthAccount(uid: uid, email: '$uid@example.test');
    controller.add(account);
  }

  @override
  Stream<AuthAccount?> get authStateChanges => controller.stream;
  @override
  AuthAccount? get currentAccount => account;
  @override
  Future<AuthAccount> signIn(String email, String password) async {
    emit('ct-$run-passenger-a');
    return account!;
  }

  @override
  Future<void> signOut() async {
    if (pendingSignOut != null) return pendingSignOut!.future;
    if (failSignOut) throw StateError('not logged');
    if (emitSignOutEvent) {
      emit(null);
    } else {
      account = null;
    }
  }

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    tokenCalls++;
    return 'must-not-be-shown';
  }

  @override
  Future<Object?> getCustomClaim(String name,
      {bool forceRefresh = false}) async {
    claimCalls++;
    if (failClaims) throw StateError('private failure detail');
    if (name == 'mobi_role' && roleQueue.isNotEmpty)
      return roleQueue.removeAt(0);
    return claims[name];
  }
}

Map<String, Object?> passengerClaims({String runId = run}) =>
    {'mobi_role': 'passenger', 'mobi_cloud_test_run': runId};
Map<String, Object?> driverClaims() => {
      'mobi_role': 'driver',
      'mobi_cloud_test_run': run,
      'mobi_driver_id': 'ct-$run-driver-502'
    };

Widget gate(FakeSession session,
        {String role = 'passenger',
        AuthOnlyConfiguration config = const AuthOnlyConfiguration(),
        Widget Function(BuildContext, AuthAccount)? builder}) =>
    MaterialApp(
      home: AuthGate(
          configurationReady: true,
          requiredRole: role,
          session: session,
          authOnly: config,
          builder: builder ?? (_, __) => const Text('protected')),
    );

void main() {
  testWidgets('normal driver ids reject Firebase path separators and controls',
      (tester) async {
    final s = FakeSession(uid: 'driver', claims: driverClaims());
    for (final value in [
      'bad/id',
      'bad.id',
      'bad#id',
      r'bad$id',
      'bad[id',
      'bad]id',
      r'bad\id',
      String.fromCharCode(1)
    ]) {
      s.claims['mobi_driver_id'] = value;
      await tester.pumpWidget(gate(s, role: 'driver'));
      s.emit('driver');
      await tester.pumpAndSettle();
      expect(find.text('protected'), findsNothing, reason: value);
      expect(find.text('계정 접근 차단'), findsOneWidget);
    }
    s.claims['mobi_driver_id'] = 'driver-502';
    s.emit('driver');
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('matching role opens normal page after claims check',
      (tester) async {
    final s = FakeSession(uid: 'uid', claims: passengerClaims());
    await tester.pumpWidget(gate(s));
    expect(find.text('protected'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  for (final expected in ['passenger', 'driver']) {
    testWidgets('$expected rejects opposite role before page construction',
        (tester) async {
      final s = FakeSession(
          uid: 'uid',
          claims: expected == 'passenger' ? driverClaims() : passengerClaims());
      var builds = 0;
      await tester.pumpWidget(gate(s, role: expected, builder: (_, __) {
        builds++;
        return const Text('protected');
      }));
      await tester.pumpAndSettle();
      expect(builds, 0);
      expect(find.text('계정 접근 차단'), findsOneWidget);
      await tester.tap(find.text('로그아웃'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      await s.controller.close();
    });
  }

  testWidgets(
      'missing role and claim exception fail closed without secret details',
      (tester) async {
    final s = FakeSession(uid: 'uid')..failClaims = true;
    await tester.pumpWidget(gate(s));
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsNothing);
    expect(find.text('계정 접근 차단'), findsOneWidget);
    expect(find.textContaining('private failure'), findsNothing);
    s.failClaims = false;
    s.emit('uid');
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('driver without mapping is blocked', (tester) async {
    final s = FakeSession(uid: 'uid', claims: {'mobi_role': 'driver'});
    await tester.pumpWidget(gate(s, role: 'driver'));
    await tester.pumpAndSettle();
    expect(find.text('계정 접근 차단'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets(
      'auth-only page never constructs business builder or exposes token',
      (tester) async {
    final s =
        FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims());
    var builds = 0;
    await tester.pumpWidget(gate(s, config: preview, builder: (_, __) {
      builds++;
      return const Text('business');
    }));
    await tester.pumpAndSettle();
    expect(builds, 0);
    expect(find.text('UID: ct-$run-passenger-a'), findsOneWidget);
    expect(find.text('mobi_role: passenger'), findsOneWidget);
    expect(find.text('mobi_cloud_test_run: $run'), findsOneWidget);
    expect(s.tokenCalls, 0);
    expect(find.textContaining('must-not-be-shown'), findsNothing);
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets(
      'auth-only rejects wrong run, foreign uid and wrong driver mapping',
      (tester) async {
    final s = FakeSession(
        uid: 'ct-$run-passenger-a',
        claims: passengerClaims(runId: 'other-run'));
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    expect(find.text('계정 접근 차단'), findsOneWidget);
    s.claims = passengerClaims();
    s.emit('foreign-uid');
    await tester.pumpAndSettle();
    expect(find.text('계정 접근 차단'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();

    final d = FakeSession(uid: 'ct-$run-driver-b', claims: driverClaims());
    await tester.pumpWidget(gate(d, config: preview, role: 'driver'));
    await tester.pumpAndSettle();
    expect(find.text('계정 접근 차단'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await d.controller.close();
  });

  testWidgets('main-project and incomplete test settings never read claims',
      (tester) async {
    final s = FakeSession(uid: 'uid', claims: passengerClaims());
    await tester.pumpWidget(gate(s,
        config: const AuthOnlyConfiguration(
            enabled: true, projectId: 'mobi-smart-transport', runId: run)));
    await tester.pumpAndSettle();
    expect(find.text('인증 테스트 설정 오류'), findsOneWidget);
    expect(s.claimCalls, 0);
    await tester.pumpWidget(gate(s,
        config: const AuthOnlyConfiguration(
            enabled: true, projectId: 'mobi-auth-cloud-test')));
    await tester.pumpAndSettle();
    expect(find.text('인증 테스트 설정 오류'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('logout invalidates pending claim response', (tester) async {
    final pending = Completer<Object?>();
    final s = FakeSession(uid: 'uid', claims: passengerClaims())
      ..roleQueue.add(pending.future);
    await tester.pumpWidget(gate(s));
    s.emit(null);
    await tester.pump();
    pending.complete('passenger');
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets(
      'account change and late old response cannot authorize new account',
      (tester) async {
    final pending = Completer<Object?>();
    final s = FakeSession(uid: 'old', claims: passengerClaims())
      ..roleQueue.add(pending.future);
    await tester.pumpWidget(gate(s));
    s.claims = driverClaims();
    s.emit('new');
    await tester.pumpAndSettle();
    pending.complete('passenger');
    await tester.pumpAndSettle();
    expect(find.text('계정 접근 차단'), findsOneWidget);
    expect(find.text('protected'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('same uid logout-login does not reuse prior claim request',
      (tester) async {
    final pending = Completer<Object?>();
    final s = FakeSession(uid: 'same', claims: passengerClaims())
      ..roleQueue.add(pending.future);
    await tester.pumpWidget(gate(s));
    s.emit(null);
    s.claims = driverClaims();
    s.emit('same');
    await tester.pumpAndSettle();
    pending.complete('passenger');
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsNothing);
    expect(find.text('계정 접근 차단'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('dispose ignores delayed response', (tester) async {
    final pending = Completer<Object?>();
    final s = FakeSession(uid: 'uid', claims: passengerClaims())
      ..roleQueue.add(pending.future);
    await tester.pumpWidget(gate(s));
    await tester.pumpWidget(const SizedBox());
    pending.complete('passenger');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await s.controller.close();
  });

  testWidgets('restoring existing account rechecks claims', (tester) async {
    final s =
        FakeSession(uid: 'ct-$run-passenger-b', claims: passengerClaims());
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    expect(find.text('UID: ct-$run-passenger-b'), findsOneWidget);
    final calls = s.claimCalls;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    expect(s.claimCalls, greaterThan(calls));
    expect(find.text('UID: ct-$run-passenger-b'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('late sign-out failure does not block a newly signed-in account',
      (tester) async {
    final pending = Completer<void>();
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..pendingSignOut = pending;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃'));
    await tester.pump();
    s.emit(null);
    s.emit('ct-$run-passenger-b');
    await tester.pumpAndSettle();
    pending.completeError(StateError('old logout'));
    await tester.pumpAndSettle();
    expect(find.text('UID: ct-$run-passenger-b'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('failed sign-out stays blocked and allows retry', (tester) async {
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..failSignOut = true;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.textContaining('로그아웃하지 못했습니다'), findsOneWidget);
    expect(find.textContaining('UID:'), findsNothing);
    s.failSignOut = false;
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('stream error blocks previously permitted page', (tester) async {
    final s = FakeSession(uid: 'uid', claims: passengerClaims());
    await tester.pumpWidget(gate(s));
    await tester.pumpAndSettle();
    s.controller.addError(StateError('private'));
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsNothing);
    expect(find.text('계정 접근 차단'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('successful sign-out without stream event releases protected UI',
      (tester) async {
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..emitSignOutEvent = false;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.textContaining('UID:'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  for (final outcome in [
    'sdk-null',
    'null-event',
    'failure',
    'still-signed-in'
  ]) {
    testWidgets('logout intent survives duplicate UID: $outcome',
        (tester) async {
      final pending = Completer<void>();
      final s =
          FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
            ..pendingSignOut = pending;
      await tester.pumpWidget(gate(s, config: preview));
      await tester.pumpAndSettle();
      final calls = s.claimCalls;
      await tester.tap(find.text('로그아웃'));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        s.emit('ct-$run-passenger-a');
        await tester.pumpAndSettle();
        expect(find.text('로그아웃 중'), findsOneWidget);
        expect(find.textContaining('UID:'), findsNothing);
        expect(s.claimCalls, calls);
      }
      if (outcome == 'sdk-null') s.account = null;
      if (outcome == 'null-event') s.emit(null);
      if (outcome == 'failure') {
        pending.completeError(StateError('private failure'));
      } else {
        pending.complete();
      }
      await tester.pumpAndSettle();
      if (outcome == 'failure' || outcome == 'still-signed-in') {
        final message =
            outcome == 'failure' ? '로그아웃하지 못했습니다' : '로그아웃 상태를 확인할 수 없습니다';
        s.emit('ct-$run-passenger-a');
        await tester.pumpAndSettle();
        expect(find.textContaining(message), findsOneWidget);
        expect(find.textContaining('UID:'), findsNothing);
        s.pendingSignOut = null;
        await tester.tap(find.text('로그아웃')); // Explicit retry.
        await tester.pumpAndSettle();
      }
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.enterText(find.byType(TextField).first, 'test@example.test');
      await tester.enterText(find.byType(TextField).last, 'fake-password');
      await tester.tap(find.text('로그인'));
      await tester.pumpAndSettle();
      expect(find.text('UID: ct-$run-passenger-a'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await s.controller.close();
    });
  }

  testWidgets('previous claim completion cannot reopen pending logout',
      (tester) async {
    final pending = Completer<void>();
    final claim = Completer<Object?>();
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..pendingSignOut = pending;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    s.roleQueue.add(claim.future);
    s.emit('ct-$run-passenger-a');
    // The old frame still has a logout button while claims are pending.
    await tester.tap(find.text('로그아웃'));
    await tester.pump();
    claim.complete('passenger');
    await tester.pumpAndSettle();
    expect(find.text('로그아웃 중'), findsOneWidget);
    expect(find.textContaining('UID:'), findsNothing);
    s.emit(null);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets(
      'early null then explicit same-user login ignores old logout error',
      (tester) async {
    final pending = Completer<void>();
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..pendingSignOut = pending;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃'));
    await tester.pump();
    s.emit(null);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'test@example.test');
    await tester.enterText(find.byType(TextField).last, 'fake-password');
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    pending.completeError(StateError('old logout'));
    await tester.pumpAndSettle();
    expect(find.text('UID: ct-$run-passenger-a'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('stale queued events cannot erase newer current SDK account',
      (tester) async {
    final s =
        FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims());
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    s.emit('ct-$run-passenger-b');
    await tester.pumpAndSettle();
    s.controller.add(null);
    s.controller.add(const AuthAccount(uid: 'ct-$run-passenger-a'));
    await tester.pumpAndSettle();
    expect(find.text('UID: ct-$run-passenger-b'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('stream error during logout permits retry without reopening',
      (tester) async {
    final pending = Completer<void>();
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..pendingSignOut = pending;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃'));
    await tester.pump();
    s.controller.addError(StateError('stream failed'));
    await tester.pumpAndSettle();
    s.emit('ct-$run-passenger-a');
    await tester.pumpAndSettle();
    expect(find.textContaining('UID:'), findsNothing);
    s.pendingSignOut = null;
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    pending.completeError(StateError('old failure'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets(
      'normal business builder stays closed during duplicate logout events',
      (tester) async {
    final pending = Completer<void>();
    final s = FakeSession(uid: 'uid', claims: passengerClaims())
      ..pendingSignOut = pending;
    var builds = 0;
    await tester.pumpWidget(gate(s, builder: (_, __) {
      builds++;
      return const Text('protected');
    }));
    await tester.pumpAndSettle();
    s.claims = driverClaims();
    s.emit('uid'); // Shared Gate's role-denial page offers logout.
    await tester.pumpAndSettle();
    final before = builds;
    await tester.tap(find.text('로그아웃'));
    await tester.pump();
    s.claims = passengerClaims();
    s.emit('uid');
    await tester.pumpAndSettle();
    expect(builds, before);
    expect(find.text('protected'), findsNothing);
    s.emit(null);
    pending.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  testWidgets('dispose during pending logout ignores late failure and events',
      (tester) async {
    final pending = Completer<void>();
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..pendingSignOut = pending;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    s.emit('ct-$run-passenger-a');
    pending.completeError(StateError('old logout'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await s.controller.close();
  });

  testWidgets(
      'late signout success cannot erase a different newly signed-in account',
      (tester) async {
    final pending = Completer<void>();
    final s = FakeSession(uid: 'ct-$run-passenger-a', claims: passengerClaims())
      ..pendingSignOut = pending;
    await tester.pumpWidget(gate(s, config: preview));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃'));
    await tester.pump();
    s.emit(null);
    s.emit('ct-$run-passenger-b');
    await tester.pumpAndSettle();
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('UID: ct-$run-passenger-b'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await s.controller.close();
  });

  test('reviewed registration rejects mixed app ids, sender and api key', () {
    FirebaseWebConfiguration cfg({String? key, String? app, String? sender}) =>
        FirebaseWebConfiguration(
            apiKey: key ?? 'AIzaSyAfKjXX3LtVE9iaVmcSjXKxl0VIu1x6hAU',
            appId: app ?? '1:189730626159:web:407d25db8c026703170b9a',
            messagingSenderId: sender ?? '189730626159',
            projectId: 'mobi-auth-cloud-test',
            authDomain: 'mobi-auth-cloud-test.firebaseapp.com');
    expect(preview.matchesWebConfiguration(cfg(), requiredRole: 'passenger'),
        isTrue);
    expect(preview.matchesWebConfiguration(cfg(), requiredRole: 'driver'),
        isFalse);
    expect(
        preview.matchesWebConfiguration(cfg(key: 'main-key'),
            requiredRole: 'passenger'),
        isFalse);
    expect(
        preview.matchesWebConfiguration(cfg(sender: '882602390759'),
            requiredRole: 'passenger'),
        isFalse);
    expect(
        preview.matchesWebConfiguration(
            cfg(app: '1:882602390759:web:461d3d1331226ae71e1e42'),
            requiredRole: 'passenger'),
        isFalse);
  });
}
