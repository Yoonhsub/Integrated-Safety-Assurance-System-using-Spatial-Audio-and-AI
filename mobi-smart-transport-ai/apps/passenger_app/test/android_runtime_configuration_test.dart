import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/main.dart' as app;
import 'package:mobi_passenger_app/src/app.dart';
import 'auth_only_app_test.dart' as auth;
import 'package:mobi_passenger_app/src/services/api_base_url.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';

void main() {
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
  testWidgets('unconfigured Android keeps both features blocked', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    try {
      await app.main();
      await tester.pump();
      expect(find.text('AI 비전 · 공간음향'), findsNothing);
      expect(find.text('노선 정보 질문'), findsNothing);
      expect(find.textContaining('UNAVAILABLE'), findsOneWidget);
      expect(find.textContaining('Android 로그인 설정'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('verified Android passenger sees the two feature entries', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final session = auth.Session('passenger');
    addTearDown(session.events.close);
    try {
      await tester.pumpWidget(MobiApp(firebaseConfigured: true, authSession: session));
      await tester.pumpAndSettle();
      expect(find.text('AI 비전 · 공간음향'), findsOneWidget);
      expect(find.text('노선 정보 질문'), findsOneWidget);
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
