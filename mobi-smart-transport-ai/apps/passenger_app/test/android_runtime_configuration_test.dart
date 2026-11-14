import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/main.dart' as app;
import 'package:mobi_passenger_app/src/app.dart';
import 'auth_only_app_test.dart' as auth;
import 'package:mobi_passenger_app/src/services/api_base_url.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';
import 'package:mobi_passenger_app/src/pages/passenger_presentation.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'vision_observation_tts_test.dart' show FakeTts;

class _SignOutSession extends auth.Session {
  _SignOutSession() : super('passenger');

  bool signedOut = false;

  @override
  AuthAccount? get currentAccount => signedOut ? null : super.currentAccount;

  @override
  Future<void> signOut() async {
    signedOut = true;
    events.add(null);
  }
}

void main() {
  testWidgets(
      'Android home describes on tap and opens on a matching second tap',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final engine = FakeTts();
    final speech = SpeechPriorityCoordinator(engine);
    addTearDown(speech.dispose);
    var opened = 0;
    try {
      await tester.pumpWidget(MaterialApp(
        home: PassengerLanding(speech: speech, onOnline: () => opened++),
      ));
      final route = find.text('노선 정보 검색');
      await tester.tap(route);
      await tester.pump();
      expect(engine.spoken.single, contains('도착 정보'));
      expect(opened, 0);
      await tester.pump(const Duration(milliseconds: 501));
      await tester.tap(route);
      await tester.pump();
      expect(opened, 0);
      await tester.tap(find.text('장애물 탐지'));
      await tester.pump();
      await tester.tap(route);
      await tester.pump();
      expect(opened, 0);
      await tester.tap(route);
      await tester.pump();
      expect(opened, 1);
      expect(engine.playing!.isCompleted, isTrue);
      final accessibleButton = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == '노선 정보 검색',
        ),
      );
      accessibleButton.properties.onTap!();
      expect(opened, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('normal Android defaults to USB reverse loopback', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(resolveApiBaseUrl(), 'http://127.0.0.1:8000');
  });
  test('debug loopback and release HTTPS configurations differ', () {
    expect(
        androidApiConfigurationIssue('http://127.0.0.1:8000', release: false),
        null);
    expect(androidApiConfigurationIssue('http://127.0.0.1:8000', release: true),
        isNotNull);
    expect(
        androidApiConfigurationIssue('https://api.example.test', release: true),
        null);
    expect(
        androidApiConfigurationIssue('http://192.168.1.2:8000', release: false),
        isNotNull);
    expect(
        androidApiConfigurationIssue('https://user:password@api.example.test',
            release: false),
        isNotNull);
  });
  testWidgets('unconfigured Android keeps both features blocked',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    try {
      await app.main();
      await tester.pump();
      expect(find.text('장애물 탐지'), findsNothing);
      expect(find.text('노선 정보 검색'), findsNothing);
      expect(find.textContaining('UNAVAILABLE'), findsOneWidget);
      expect(find.textContaining('Android 로그인 설정'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android home opens route search and signs out from the app bar',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final session = _SignOutSession();
    addTearDown(session.events.close);
    try {
      await tester
          .pumpWidget(MobiApp(firebaseConfigured: true, authSession: session));
      await tester.pumpAndSettle();
      expect(find.text('장애물 탐지'), findsOneWidget);
      expect(find.text('노선 정보 검색'), findsOneWidget);
      final buttons = find.byWidgetPredicate(
          (widget) => widget is FilledButton || widget is OutlinedButton);
      expect(buttons, findsNWidgets(3));
      expect(find.text('TAGO 실데이터 테스트'), findsNothing);
      expect(find.text('동시 기기 테스트 (임시)'), findsNothing);
      for (final button in tester.widgetList<ButtonStyleButton>(buttons)) {
        final foreground = button.style!.foregroundColor!.resolve({})!;
        final background = button.style!.backgroundColor!.resolve({})!;
        final luminances = [
          foreground.computeLuminance(),
          background.computeLuminance()
        ]..sort();
        expect((luminances.last + .05) / (luminances.first + .05),
            greaterThanOrEqualTo(7));
      }
      final search = tester.widget<Semantics>(find.byWidgetPredicate((widget) =>
          widget is Semantics && widget.properties.label == '노선 정보 검색'));
      search.properties.onTap!();
      await tester.pumpAndSettle();
      expect(find.text('Mock 데이터 테스트'), findsNothing);
      expect(find.text('실제 API 데이터 테스트'), findsNothing);
      expect(find.text('홈으로 가기'), findsOneWidget);
      expect(find.text('이 이름으로 시작'), findsOneWidget);
      await tester.tap(find.text('홈으로 가기'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(AppBar), matching: find.text('로그아웃')));
      await tester.pumpAndSettle();
      expect(session.signedOut, isTrue);
      expect(find.text('MOBI 로그인'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
  testWidgets('bundled approved model can be prepared without file selection',
      (tester) async {
    final unified = await rootBundle.load(
        'assets/models/yolo11n_unified_bus_obstacle_stop_v4_float32.tflite');
    expect(
        verifyModel(unified.buffer
            .asUint8List(unified.offsetInBytes, unified.lengthInBytes)),
        unifiedV4ModelHash);
    final data = await rootBundle
        .load('assets/models/yolo11n_bus_door_v1_float32.tflite');
    expect(
        verifyModel(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
        busDoorModelHash);
  });
}
