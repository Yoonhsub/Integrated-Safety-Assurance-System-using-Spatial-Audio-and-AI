import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/app.dart';
import 'package:mobi_passenger_app/src/pages/passenger_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomeSession implements AuthSession {
  final events = StreamController<AuthAccount?>.broadcast(sync: true);
  AuthAccount? account;
  bool failLogin = false, failLogout = false;
  int logoutCalls = 0;
  @override
  AuthAccount? get currentAccount => account;
  @override
  Stream<AuthAccount?> get authStateChanges => events.stream;
  @override
  Future<AuthAccount> signIn(String email, String password) async {
    if (failLogin) throw StateError('rejected');
    account = const AuthAccount(uid: 'passenger-one');
    events.add(account);
    return account!;
  }

  @override
  Future<void> signOut() async {
    logoutCalls++;
    if (failLogout) throw StateError('offline');
    account = null;
    events.add(null);
  }

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async => null;
  @override
  Future<Object?> getCustomClaim(String name,
          {bool forceRefresh = false}) async =>
      name == 'mobi_role' ? 'passenger' : null;
}

void main() {
  testWidgets('Android login, two home actions, logout failure and retry',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final session = HomeSession();
    addTearDown(session.events.close);
    await tester
        .pumpWidget(MobiApp(firebaseConfigured: true, authSession: session));
    await tester.pumpAndSettle();
    expect(find.text('MOBI 로그인'), findsOneWidget);
    expect(find.text('노선 정보 검색'), findsNothing);
    expect(find.text('장애물 탐지'), findsNothing);
    session.failLogin = true;
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    expect(find.text('노선 정보 검색'), findsNothing);
    session.failLogin = false;
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    expect(find.text('노선 정보 검색'), findsOneWidget);
    expect(find.text('장애물 탐지'), findsOneWidget);
    expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('로그아웃')),
        findsOneWidget);
    final logout = tester.getCenter(find.text('로그아웃'));
    expect(
        logout.dx,
        greaterThan(
            tester.view.physicalSize.width / tester.view.devicePixelRatio / 2));
    session.failLogout = true;
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    // Latest main preserves the signed-in home when logout fails.
    expect(find.text('노선 정보 검색'), findsOneWidget);
    expect(find.text('로그아웃하지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
    session.failLogout = false;
    await tester.tap(find.text('로그아웃'));
    await tester.pumpAndSettle();
    expect(find.text('MOBI 로그인'), findsOneWidget);
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    expect(find.text('노선 정보 검색'), findsOneWidget);
    expect(session.logoutCalls, 2);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
        '$platform exposes feature labels, hints and screen reader activation',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final semantics = tester.ensureSemantics();
      var opened = 0;
      await tester.pumpWidget(MaterialApp(
        home: PassengerLanding(onOnline: () => opened++),
        routes: {
          '/standalone-vision': (_) =>
              const Scaffold(body: Text('vision destination'))
        },
      ));
      for (final label in ['노선 정보 검색', '장애물 탐지']) {
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
        expect(node.getSemanticsData().hint, isNotEmpty);
        tester
            .widget<Semantics>(find.byWidgetPredicate((widget) =>
                widget is Semantics && widget.properties.label == label))
            .properties
            .onTap!();
        await tester.pumpAndSettle();
        if (label == '노선 정보 검색') {
          expect(opened, 1);
        } else {
          expect(find.text('vision destination'), findsOneWidget);
        }
      }
      Navigator.of(tester.element(find.text('vision destination'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('노선 정보 검색'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
      semantics.dispose();
    });
  }
}
