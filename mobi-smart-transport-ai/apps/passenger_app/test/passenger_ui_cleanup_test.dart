import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/pages/data_mode_selection_page.dart';
import 'package:mobi_passenger_app/src/widgets/mock_control_panel.dart';
import 'passenger_login_home_test.dart' show HomeSession;

void main() {
  testWidgets(
      'mock event injection controls removed but repeat and refresh remain',
      (tester) async {
    var injected = 0, repeated = 0, refreshed = 0;
    void inject() => injected++;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: V3MockControlPanel(
      isBusy: false,
      onArrivedAtStop: inject,
      onLeftWaitingArea: inject,
      onDangerZone: inject,
      onReturnedToStop: inject,
      onWrongBusNear: inject,
      onTargetBusMid: inject,
      onTargetBusNear: inject,
      onNoBeacon: inject,
      onBusPassed: inject,
      onBoardingPrompt: inject,
      onBoardedSuccess: inject,
      onRepeatScript: () => repeated++,
      onRefreshArrivals: () => refreshed++,
      latestBeaconDecision: null,
      latestGeofenceMessage: null,
    ))));
    for (final label in [
      'Boarding Prompt',
      'Boarded OK',
      '도착',
      '대기 범위 이탈',
      '위험 구역',
      '정류장 복귀',
      '잘못된 버스 근접',
      '타야 할 버스 중간',
      '타야 할 버스 근접',
      '비컨 없음',
      '버스 지나감'
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.byType(OutlinedButton), findsNWidgets(2));
    await tester.tap(find.text('Repeat Line'));
    await tester.tap(find.text('도착정보 갱신'));
    expect(injected, 0);
    expect(repeated, 1);
    expect(refreshed, 1);
  });

  testWidgets(
      'data choices remain accessible and demo selection does not imply live data',
      (tester) async {
    String? selected;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home:
            DataModeSelectionPage(onModeSelected: (mode) => selected = mode)));
    final choice = tester.widget<Semantics>(find.byWidgetPredicate((widget) =>
        widget is Semantics &&
        (widget.properties.label?.startsWith('시연 데이터.') ?? false)));
    expect(choice.properties.button, isTrue);
    expect(choice.properties.label, contains('mock 데이터'));
    choice.properties.onTap!();
    expect(selected, 'mock');
    expect(find.text('실시간 노선 검색'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
      'login remains scrollable with large text and keyboard-sized viewport',
      (tester) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = HomeSession();
    addTearDown(session.events.close);
    await tester.pumpWidget(MaterialApp(
        home: AuthGate(
            configurationReady: true,
            session: session,
            builder: (_, account) => const Text('signed in'))));
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('로그인'));
    await tester.tap(find.text('로그인'));
    await tester.pumpAndSettle();
    expect(find.text('signed in'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
