import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/camera_bus_test_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'phone heading starts automatically and restarts after app return',
      (tester) async {
    const channel = MethodChannel('mobi/phone_camera_heading');
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: CameraBusTestPanel(
                    ensureReady: () async => false,
                    rssi: null,
                    seenAt: null,
                    beaconName: 'A',
                    scope: 'a')))));
    await tester.pump();
    expect(find.text('휴대폰 방향 시작'), findsNothing);
    expect(calls.where((c) => c == 'listen'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(calls.where((c) => c == 'cancel'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    for (var i = 0;
        i < 8 && calls.where((c) => c == 'listen').length < 2;
        i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(calls.where((c) => c == 'listen'), hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.where((c) => c == 'cancel'), hasLength(2));
    messenger.setMockMethodCallHandler(channel, null);
  });
}
