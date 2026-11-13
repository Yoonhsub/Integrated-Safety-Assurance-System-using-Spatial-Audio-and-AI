import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/app.dart';
import 'package:mobi_passenger_app/src/pages/standalone_vision_page.dart';
import 'package:mobi_passenger_app/src/local_vision/native_local_vision_page.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'auth_only_app_test.dart' as auth;
import 'native_android_audio_test.dart' as native;
import 'vision_observation_tts_test.dart' as speech;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  Future<void> flush(WidgetTester t) async {
    for (var i = 0; i < 15; i++) {
      await t.pump();
    }
  }

  testWidgets(
      'pending Firebase and absent Backend do not block public local entry',
      (t) async {
    final network = auth.NoNetwork(), previous = HttpOverrides.current;
    HttpOverrides.global = network;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final initialization = Completer<bool>();
    try {
      await t
          .pumpWidget(MobiApp(firebaseInitialization: initialization.future));
      await flush(t);
      await t.ensureVisible(find.text('장애물 탐지'));
      await t.pumpAndSettle();
      await t.tap(find.text('장애물 탐지'));
      await t.pump();
      await t.pumpAndSettle();
      expect(find.byType(StandaloneVisionPage), findsOneWidget);
      expect(find.textContaining('Android에서 지원'), findsOneWidget);
      expect(network.attempts, 0);
      await t.pumpWidget(const SizedBox());
      initialization.complete(false);
      await flush(t);
      expect(t.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      HttpOverrides.global = previous;
    }
  });
  testWidgets(
      'online entry still requires Firebase role gate; local route does not grant auth',
      (t) async {
    final network = auth.NoNetwork(), previous = HttpOverrides.current;
    HttpOverrides.global = network;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final session = auth.Session('passenger');
    try {
      await t
          .pumpWidget(MobiApp(firebaseConfigured: true, authSession: session));
      await flush(t);
      expect(find.text('MOBI 스마트 교통 시스템'), findsNothing);
      await t.ensureVisible(find.text('노선 정보 검색'));
      await t.pumpAndSettle();
      await t.tap(find.text('노선 정보 검색'));
      await flush(t);
      expect(find.text('MOBI 스마트 교통 시스템'), findsOneWidget);
      expect(network.attempts, 0);
      await t.pumpWidget(const SizedBox());
      await flush(t);
      expect(t.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      HttpOverrides.global = previous;
      await session.events.close();
    }
  });
  testWidgets(
      'standalone camera uses bundled model and shared audio without transport or server lifecycle',
      (t) async {
    final port = native.Port(), tts = speech.FakeTts();
    final engine = SpatialVerificationEngine(
        NativeDirectionalCueOutput(port: port), tts,
        allowDirectTestCommands: false);
    final network = auth.NoNetwork(), previous = HttpOverrides.current;
    HttpOverrides.global = network;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await t
          .pumpWidget(MaterialApp(home: StandaloneVisionPage(engine: engine)));
      await flush(t);
      expect(find.textContaining('Backend 미연결'), findsOneWidget);
      expect(find.text('실제 BLE 스캔 · 비콘-버스 등록 정보 없음'), findsOneWidget);
      await t.tap(find.text('로컬 카메라·음향 시작'));
      await t.pump();
      await t.pumpAndSettle();
      final camera = t.widget<LocalVisionPage>(find.byType(LocalVisionPage));
      expect(camera.bundledModel, isTrue);
      expect(camera.previewEngine, same(engine));
      expect(camera.previewPriority!.engine, same(engine));
      expect(camera.producer, isNull);
      expect(camera.remoteApi, isNull);
      expect(camera.beforeStart, isNull);
      expect(camera.onResult, isNull);
      expect(camera.authChanges, isNull);
      expect(camera.ownerUid, isNull);
      expect(camera.remoteSessionId, isNull);
      expect(camera.previewScope, startsWith('LOCAL_DEMO:'));
      expect(camera.sessionCurrent!(), isTrue);
      final scope = camera.previewScope;
      Navigator.of(t.element(find.byType(LocalVisionPage))).pop();
      await t.pump();
      await t.pumpAndSettle();
      expect(camera.sessionCurrent!(), isFalse);
      await t.tap(find.text('로컬 카메라·음향 시작'));
      await t.pump();
      await t.pumpAndSettle();
      final next = t.widget<LocalVisionPage>(find.byType(LocalVisionPage));
      expect(next.previewScope, isNot(scope));
      expect(next.previewEngine, same(engine));
      expect(network.attempts, 0);
      await t.pumpWidget(const SizedBox());
      await flush(t);
      expect(next.sessionCurrent!(), isFalse);
      expect(port.calls, contains('dispose'));
      expect(t.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      HttpOverrides.global = previous;
    }
  });
}
