import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/concurrent_camera_panel.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'concurrent_camera_panel_test.dart' show Source, Output, Speech;

void main() {
  testWidgets('compact camera controls fit 360x800 with details in dialog',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final source = Source();
    source.emit(
        empty: true,
        jpeg: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jMgAAAABJRU5ErkJggg=='));
    final engine = SpatialVerificationEngine(Output(), Speech());
    final priority = SpeechPriorityCoordinator(engine);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
          height: 590,
          child: ConcurrentCameraPanel(
              compact: true,
              source: source,
              engine: engine,
              priority: priority,
              isCurrent: () => true)),
    ))));
    expect(t.takeException(), isNull);
    expect(t.getSize(find.byType(Image).last).height, 180);
    for (final label in ['카메라 시작', '카메라 중지', '소리 시작', '소리 중지', '자세히 듣기']) {
      final rect = t.getRect(find.text(label));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThan(590));
    }
    expect(find.byType(SingleChildScrollView), findsNothing);
    await t.tap(find.byTooltip('카메라 상태와 안내 상세'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('concurrent-camera-details-page')),
        findsOneWidget);
    expect(find.textContaining('프레임 수신 기록 없음'), findsOneWidget);
    expect(find.textContaining('촬영 시각이 아닙니다'), findsOneWidget);
    await t.tap(find.byTooltip('Close camera details'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await t.pump();
    priority.dispose();
    await engine.dispose();
    source.dispose();
  });
  testWidgets(
      'large text on a small screen keeps the page scroll free and preview controls usable',
      (t) async {
    t.view.physicalSize = const Size(360, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final source = Source();
    source.emit(
        empty: true,
        jpeg: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jMgAAAABJRU5ErkJggg=='));
    final engine = SpatialVerificationEngine(Output(), Speech());
    final priority = SpeechPriorityCoordinator(engine);
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(
            body: SizedBox(
                height: 560,
                child: ConcurrentCameraPanel(
                    compact: true,
                    source: source,
                    engine: engine,
                    priority: priority,
                    isCurrent: () => true)))));
    expect(t.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    await t.tap(find.byType(FilledButton).first);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-control-surface-page')),
        findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(t.getSize(find.byType(Image).last).height, 180);
    expect(find.byType(OutlinedButton), findsWidgets);
    final close =
        find.byKey(const ValueKey('compact-control-surface-page-close'));
    await t.ensureVisible(find.byType(OutlinedButton).last);
    expect(t.getRect(close).bottom, lessThanOrEqualTo(600));
    final detailContent = find.descendant(
        of: find.byKey(const ValueKey('compact-control-surface-page')),
        matching: find.byType(Text));
    await t.ensureVisible(detailContent.last);
    expect(t.getRect(close).bottom, lessThanOrEqualTo(600));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    priority.dispose();
    await engine.dispose();
    source.dispose();
  });

  testWidgets(
      'expanded camera controls retain the mounted source and update live',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final source = Source();
    final engine = SpatialVerificationEngine(Output(), Speech());
    final priority = SpeechPriorityCoordinator(engine);
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(
            body: SizedBox(
                height: 590,
                child: ConcurrentCameraPanel(
                    compact: true,
                    source: source,
                    engine: engine,
                    priority: priority,
                    isCurrent: () => true)))));
    expect(t.takeException(), isNull);
    await t.tap(find.textContaining('확대 보기').first);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('카메라 시작').last);
    await t.tap(find.text('카메라 시작').last);
    await t.pumpAndSettle();
    expect(source.starts, 1);
    expect(source.running, isTrue);
    expect(source.stops, 0);
    await t.ensureVisible(find.text('카메라 중지').last);
    final stop = t.widget<OutlinedButton>(find
        .ancestor(
            of: find.text('카메라 중지').last, matching: find.byType(OutlinedButton))
        .first);
    expect(stop.onPressed, isNotNull);
    await t.tap(find.text('카메라 중지').last);
    await t.pumpAndSettle();
    expect(source.running, isFalse);
    expect(source.stops, 1);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    priority.dispose();
    await engine.dispose();
    source.dispose();
  });
  testWidgets(
      'open detail dialog retires old labels when a stale frame arrives',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final source = Source(),
        engine = SpatialVerificationEngine(Output(), Speech());
    final priority = SpeechPriorityCoordinator(engine);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ConcurrentCameraPanel(
                compact: true,
                source: source,
                engine: engine,
                priority: priority,
                isCurrent: () => true))));
    await source.start();
    await t.pump();
    for (var i = 0; i < 3; i++) {
      source.emit();
      await t.pump();
    }
    await t.tap(find.byTooltip('카메라 상태와 안내 상세'));
    await t.pumpAndSettle();
    expect(source.running, isTrue);
    final detailsPage =
        find.byKey(const ValueKey('concurrent-camera-details-page'));
    expect(
        find.descendant(
            of: detailsPage, matching: find.textContaining('보도 기둥 1개')),
        findsOneWidget);
    source.emit(stale: true);
    await t.pump();
    expect(
        find.descendant(
            of: detailsPage, matching: find.textContaining('보도 기둥 1개')),
        findsNothing);
    expect(
        find.descendant(
            of: detailsPage,
            matching: find.textContaining('현재 화면을 확인하기 어렵습니다')),
        findsWidgets);
    expect(
        find.descendant(
            of: detailsPage, matching: find.textContaining('오래된 관찰')),
        findsOneWidget);
    await t.tap(find.byTooltip('Close camera details'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await t.pump();
    priority.dispose();
    await engine.dispose();
    source.dispose();
  });
}
