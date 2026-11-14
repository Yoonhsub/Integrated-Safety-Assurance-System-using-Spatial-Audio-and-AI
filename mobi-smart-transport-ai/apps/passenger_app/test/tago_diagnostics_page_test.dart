import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/pages/tago_diagnostics_page.dart';
import 'package:mobi_passenger_app/src/services/tago_diagnostics_client.dart';

class FakeTago implements TagoDiagnosticsClient {
  final calls = <String>[];
  bool closed = false;
  Completer<TagoDiagnosticResult>? pending;
  TagoDiagnosticResult result = const TagoDiagnosticResult(
      status: TagoDiagnosticStatus.success,
      message: 'health only',
      source: 'BACKEND');
  @override
  String get backendOrigin => 'https://configured.example';
  @override
  Future<TagoDiagnosticResult> health() async {
    calls.add('health');
    return pending == null ? result : await pending!.future;
  }

  @override
  Future<TagoDiagnosticResult> arrivals(
      {required String cityCode, required String stopId}) async {
    calls.add('arrivals:$cityCode:$stopId');
    return result;
  }

  @override
  Future<TagoDiagnosticResult> locations(
      {required String cityCode, required String routeId}) async {
    calls.add('locations:$cityCode:$routeId');
    return result;
  }

  @override
  void close() {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> mount(WidgetTester t, FakeTago client,
      {bool owned = false}) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        home: TagoDiagnosticsPage(client: client, ownsClient: owned)));
  }

  Future<void> tap(WidgetTester t, String label) async {
    if (find.text(label).evaluate().isEmpty) {
      await t.scrollUntilVisible(find.text(label), 180,
          scrollable: find
              .byWidgetPredicate((w) =>
                  w is Scrollable && w.axisDirection == AxisDirection.down)
              .last);
    }
    await t.ensureVisible(find.text(label));
    await t.tap(find.text(label));
    await t.pump();
  }

  testWidgets(
      'no automatic request; configured origin fixed and owned client closes',
      (t) async {
    final client = FakeTago();
    await mount(t, client, owned: true);
    expect(client.calls, isEmpty);
    expect(find.textContaining('https://configured.example'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    await tap(t, '서버 상태 조회');
    expect(client.calls, ['health']);
    expect(find.text('출처: BACKEND'), findsOneWidget);
    expect(find.textContaining('HTTP 200만으로'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    expect(client.closed, isTrue);
  });
  testWidgets(
      'only entered IDs are passed to explicit arrival and location actions',
      (t) async {
    final client = FakeTago();
    await mount(t, client);
    await tap(t, '도착 조회');
    expect(client.calls, isEmpty);
    expect(find.text('실제 도시 코드를 입력하세요.'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, '실제 도시 코드'), ' 33010 ');
    await t.enterText(find.widgetWithText(TextField, '실제 정류장 ID'), 'STOP123');
    await t.enterText(find.widgetWithText(TextField, '실제 노선 ID'), 'ROUTE456');
    await tap(t, '도착 조회');
    expect(client.calls.last, 'arrivals:33010:STOP123');
    await tap(t, '1 입력');
    await tap(t, '위치 조회');
    expect(client.calls.last, 'locations:33010:ROUTE456');
    await t.pumpWidget(const SizedBox());
    expect(client.closed, isFalse);
  });
  testWidgets(
      'mock fallback never appears as real-data success; original and receipt times distinct',
      (t) async {
    final client = FakeTago()
      ..result = TagoDiagnosticResult(
          status: TagoDiagnosticStatus.fallback,
          message: 'demo response',
          source: 'MOCK',
          updatedAt: DateTime.utc(2026, 1, 1),
          receivedAt: DateTime.utc(2026, 1, 2),
          warnings: ['not real']);
    await mount(t, client);
    await tap(t, '서버 상태 조회');
    expect(find.text('대체 응답 · 실데이터 성공 아님'), findsOneWidget);
    expect(find.text('출처: MOCK'), findsOneWidget);
    expect(find.textContaining('원본 데이터 시각: 2026-01-01'), findsOneWidget);
    expect(find.textContaining('앱 수신 시각: 2026-01-02'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  for (final item in {
    TagoDiagnosticStatus.unauthorized: '401 · 로그인/인증 필요',
    TagoDiagnosticStatus.empty: '결과 0건 · 운행 없음의 증거 아님',
    TagoDiagnosticStatus.error: '조회 오류',
    TagoDiagnosticStatus.unsupported: '현재 서버에서 지원하지 않는 조회',
  }.entries) {
    testWidgets('distinct result ${item.key.name}', (t) async {
      final client = FakeTago()
        ..result =
            TagoDiagnosticResult(status: item.key, message: 'diagnostic');
      await mount(t, client);
      await tap(t, '서버 상태 조회');
      expect(find.text(item.value), findsOneWidget);
      expect(find.textContaining('제공되지 않음 · 신선도 확인 불가'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'duplicate blocked and canceled pending response never replaces current state',
      (t) async {
    final client = FakeTago()..pending = Completer<TagoDiagnosticResult>();
    await mount(t, client);
    await tap(t, '서버 상태 조회');
    await tap(t, '1 입력');
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '서버 상태 조회'))
            .onPressed,
        isNull);
    await tap(t, '2 결과');
    await tap(t, '결과 수신 중지');
    client.pending!.complete(const TagoDiagnosticResult(
        status: TagoDiagnosticStatus.success, message: 'late result'));
    await t.pump();
    expect(find.text('late result'), findsNothing);
    expect(client.calls, ['health']);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('disposal ignores pending response', (t) async {
    final client = FakeTago()..pending = Completer<TagoDiagnosticResult>();
    await mount(t, client);
    await tap(t, '서버 상태 조회');
    await t.pumpWidget(const SizedBox());
    client.pending!.complete(const TagoDiagnosticResult(
        status: TagoDiagnosticStatus.success, message: 'late'));
    await t.pump();
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'normal result stays concise; records and full metadata require explicit details',
      (t) async {
    final client = FakeTago()
      ..result = TagoDiagnosticResult(
          status: TagoDiagnosticStatus.success,
          message: 'response',
          source: 'PUBLIC_API',
          records: List.generate(
              100,
              (i) =>
                  {'nodeId': 'STOP$i', 'positionType': 'LAST_REPORTED_STOP'}),
          totalCount: 150,
          truncated: true,
          fetchedAt: DateTime.utc(2026, 1, 3));
    await mount(t, client);
    await tap(t, '서버 상태 조회');
    expect(t.takeException(), isNull);
    expect(find.textContaining('nodeId:'), findsNothing);
    expect(t.getRect(find.text('응답 상세 보기')).bottom, lessThan(800));
    await tap(t, '응답 상세 보기');
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('서버 조회 시각: 2026-01-03'), findsOneWidget);
    await tap(t, '닫기');
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('large text remains accessible without overflow', (t) async {
    final client = FakeTago();
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: TagoDiagnosticsPage(client: client)));
    expect(t.takeException(), isNull);
    await tap(t, '서버 상태 조회');
    expect(t.takeException(), isNull);
    await tap(t, '응답 상세 보기');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await tap(t, '닫기');
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
  });
}
