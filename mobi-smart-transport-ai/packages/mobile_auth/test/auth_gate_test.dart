import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';

class _FakeSession implements AuthSession {
  final StreamController<AuthAccount?> _controller =
      StreamController<AuthAccount?>.broadcast();
  AuthAccount? account;

  @override
  Stream<AuthAccount?> get authStateChanges => _controller.stream;
  @override
  AuthAccount? get currentAccount => account;
  @override
  Future<AuthAccount> signIn(String email, String password) async {
    account = AuthAccount(uid: 'uid-test', email: email);
    _controller.add(account);
    return account!;
  }

  @override
  Future<void> signOut() async {
    account = null;
    _controller.add(null);
  }

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async => 'token';
  @override
  Future<Object?> getCustomClaim(
    String name, {
    bool forceRefresh = false,
  }) async =>
      null;
}

void main() {
  testWidgets('shows sign-in for a pre-registered account session', (
    tester,
  ) async {
    final session = _FakeSession();
    await tester.pumpWidget(
      MaterialApp(
        home: AuthGate(
          configurationReady: true,
          session: session,
          builder: (_, account) => Text('uid=${account.uid}'),
        ),
      ),
    );
    session._controller.add(null);
    await tester.pump();
    expect(find.text('관리자가 사전 등록한 계정으로 로그인하세요.'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField).first, 'passenger@example.test');
    await tester.enterText(find.byType(TextField).last, 'test-password');
    await tester.tap(find.text('로그인'));
    await tester.pump();
    expect(find.text('uid=uid-test'), findsOneWidget);
    await session._controller.close();
  });

  testWidgets('requires explicit web Firebase configuration', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AuthGate(configurationReady: false, builder: _unusedBuilder),
      ),
    );
    expect(find.text('Firebase 설정 필요'), findsOneWidget);
  });
}

Widget _unusedBuilder(BuildContext context, AuthAccount account) =>
    const SizedBox();
