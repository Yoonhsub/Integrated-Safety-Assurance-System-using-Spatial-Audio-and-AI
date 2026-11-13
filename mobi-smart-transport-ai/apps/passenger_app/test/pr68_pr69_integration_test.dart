import 'package:mobi_passenger_app/src/pages/passenger_presentation.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/app.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/hardware_bus_page.dart';
import 'package:mobi_passenger_app/src/pages/standalone_vision_page.dart';
import 'auth_only_app_test.dart' as auth;

void main() {
  testWidgets(
      'hardware diagnostics and standalone Vision both open without auth or autoplay',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final initializing = Completer<bool>();
    final noNetwork = auth.NoNetwork(), previous = HttpOverrides.current;
    final calls = <String>[];
    HttpOverrides.global = noNetwork;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    const channel = MethodChannel('mobi.passenger/hardware-tone');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      return null;
    });
    try {
      await t.pumpWidget(MobiApp(firebaseInitialization: initializing.future));
      await t.pumpAndSettle();
      expect(find.text('장애물 탐지'), findsOneWidget);
      await t.tap(find.text('장애물 탐지'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('이어폰·BLE 기기 점검'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('실기기 연동확인 · BLE/WT901/HRTF'), 180);
      await t.pumpAndSettle();
      await t.tap(find.text('실기기 연동확인 · BLE/WT901/HRTF'));
      await t.pumpAndSettle();
      expect(find.byType(HardwareBusPage), findsOneWidget);
      expect(calls.where((c) => c == 'start' || c == 'update'), isEmpty);
      expect(noNetwork.attempts, 0);
      Navigator.of(t.element(find.byType(HardwareBusPage))).pop();
      await t.pumpAndSettle();
      Navigator.of(t.element(find.byType(DeviceCheckPage))).pop();
      await t.pumpAndSettle();
      expect(find.byType(StandaloneVisionPage), findsOneWidget);
      expect(noNetwork.attempts, 0);
      await t.pumpWidget(const SizedBox());
      initializing.complete(false);
      await t.pump();
      expect(t.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      HttpOverrides.global = previous;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });
}
