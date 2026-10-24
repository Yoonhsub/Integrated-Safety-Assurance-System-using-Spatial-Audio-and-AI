import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_driver_app/src/app.dart';

const run = 'auth-20261023-919e07bd';

class Session implements AuthSession {
  Session(this.role);
  final String role;
  final events = StreamController<AuthAccount?>.broadcast(sync: true);
  @override
  AuthAccount? get currentAccount => AuthAccount(uid: 'ct-$run-$role-a');
  @override
  Stream<AuthAccount?> get authStateChanges => events.stream;
  @override
  Future<AuthAccount> signIn(String email, String password) async =>
      currentAccount!;
  @override
  Future<void> signOut() async {}
  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async =>
      throw StateError('No Backend token request allowed');
  @override
  Future<Object?> getCustomClaim(String name,
          {bool forceRefresh = false}) async =>
      {
        'mobi_role': role,
        'mobi_cloud_test_run': run,
        'mobi_driver_id': role == 'driver' ? 'ct-$run-driver-502' : null
      }[name];
}

class NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('No network request allowed');
  }
}

void main() {
  for (final role in ['driver', 'passenger']) {
    testWidgets(
        'actual driver app auth-only $role has no business page or network',
        (tester) async {
      final session = Session(role);
      final network = NoNetwork();
      final previous = HttpOverrides.current;
      HttpOverrides.global = network;
      try {
        await tester.pumpWidget(MobiApp(
            firebaseConfigured: true,
            authSession: session,
            authOnly: const AuthOnlyConfiguration(
                enabled: true, projectId: 'mobi-auth-cloud-test', runId: run)));
        await tester.pumpAndSettle();
        expect(network.attempts, 0);
        if (role == 'driver') {
          expect(find.text('UID: ct-$run-$role-a'), findsOneWidget);
          expect(find.text('인증 전용 테스트 · Backend 데이터 요청 없음'), findsOneWidget);
          await tester.binding.handlePushRoute('/v3-guidance');
          await tester.pumpAndSettle();
          expect(find.text('인증 전용 테스트 · Backend 데이터 요청 없음'), findsWidgets);
          expect(network.attempts, 0);
        } else {
          expect(find.text('계정 접근 차단'), findsOneWidget);
          expect(find.textContaining('UID:'), findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      } finally {
        HttpOverrides.global = previous;
        await session.events.close();
      }
    });
  }
}
