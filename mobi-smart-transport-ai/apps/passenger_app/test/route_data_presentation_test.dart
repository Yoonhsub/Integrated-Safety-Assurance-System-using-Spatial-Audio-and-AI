import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:mobi_passenger_app/src/services/route_data_presentation.dart';
import 'package:mobi_passenger_app/src/widgets/route_data_status.dart';

void main() {
  final now = DateTime.utc(2026, 11, 13, 12);
  V3BusArrival arrival({String? at}) => V3BusArrival.fromJson({
        'routeNo': '502',
        'stopId': 'stop',
        'arrivalMinutes': 3,
        if (at != null) 'updatedAt': at,
      });
  test('missing/invalid observation timestamp never uses response time', () {
    expect(arrival().updatedAt, isNull);
    expect(arrival(at: 'bad').updatedAt, isNull);
    expect(arrivalFreshnessLabel([arrival()], now), contains('시각 미확인'));
    final parsed = arrival(at: '2026-11-13T21:00:00+09:00');
    expect(parsed.updatedAt!.toUtc(), now);
  });
  test('oldest observation controls age, future timestamp is error', () {
    final old = arrival(
        at: now.subtract(const Duration(seconds: 30)).toIso8601String());
    final fresh =
        arrival(at: now.subtract(const Duration(seconds: 1)).toIso8601String());
    expect(arrivalFreshnessLabel([fresh, old], now), contains('30초 이상'));
    expect(arrivalFreshnessLabel([fresh], now), contains('이후 운행 변동 가능'));
    expect(
        arrivalFreshnessLabel([
          arrival(at: now.add(const Duration(seconds: 1)).toIso8601String())
        ], now),
        contains('시각 오류'));
    expect(arrivalFreshnessLabel([fresh, arrival()], now), contains('시각 미확인'));
  });
  test('mock/cache/unknown never upgraded by provider or verification fields',
      () {
    for (final source in ['MOCK', 'CACHE', 'UNKNOWN', 'ERROR']) {
      final plan = V3RoutePlanCandidate.fromJson({
        'fallbackSource': source,
        'planSource': 'ODSAY_ENRICHED',
        'verificationStatus': 'VERIFIED_WITH_TAGO',
      });
      expect(routePlanSourceLabel(plan), routeDataSourceLabel(source));
      expect(routePlanSourceLabel(plan), isNot(contains('실시간 도착정보 검증')));
    }
    expect(routeDataSourceLabel('MOCK'), contains('실제 버스 운행 정보 아님'));
    expect(routeDataSourceLabel('CACHE'), contains('원본 출처와 최신 여부 미확인'));
    expect(routeDataSourceLabel('PUBLIC_API'), contains('차량 식별 확인 아님'));
  });
  test('missing provenance parses unknown, not synthetic live or mock claim',
      () {
    expect(V3RoutePlanCandidate.fromJson({}).fallbackSource, 'UNKNOWN');
    expect(V3RoutePlanResponse.fromJson({}).fallbackSource, 'UNKNOWN');
    expect(V3BusArrivalsResponse.fromJson({}).fallbackSource, 'UNKNOWN');
  });
  test('new empty response must not revive earlier plan arrivals', () {
    final planned = [arrival()];
    expect(displayedRouteArrivals(latest: [], planned: planned), isEmpty);
    expect(
        displayedRouteArrivals(latest: null, planned: planned), same(planned));
    final latest = [arrival(at: now.toIso8601String())];
    expect(
        displayedRouteArrivals(latest: latest, planned: planned), same(latest));
  });
  test('failure instructions are actionable without claiming shutdown', () {
    expect(routeFailureNextAction('NO_ROUTE'), contains('다른 목적지'));
    expect(routeFailureNextAction('NO_ROUTE'), contains('운행 종료를 뜻하지는 않습니다'));
    expect(routeFailureNextAction('NOT_FOUND'), contains('위치 권한'));
    expect(routeFailureNextAction('NEEDS_CHOICE'), contains('선택'));
    expect(routeFailureNextAction('ERROR'), contains('네트워크'));
  });
  testWidgets('status exposes source, unknown age and identity limitation',
      (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RouteDataStatus(
      source: 'CACHE',
      arrivals: [arrival()],
      now: now,
      planningSnapshot: true,
    ))));
    expect(find.textContaining('저장된 자료'), findsOneWidget);
    expect(find.textContaining('시각 미확인'), findsOneWidget);
    expect(find.textContaining('경로 계산 당시 자료'), findsOneWidget);
    expect(find.textContaining('눈앞 차량'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('저장된 자료')), findsWidgets);
    semantics.dispose();
  });
  testWidgets('empty failed query displays no arrivals and refresh next step',
      (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RouteDataStatus(
      source: 'ERROR',
      arrivals: const [],
      now: now,
    ))));
    expect(find.textContaining('조회 실패'), findsOneWidget);
    expect(find.textContaining('표시할 도착 정보가 없습니다'), findsOneWidget);
  });
  testWidgets('status reevaluates age without inventing a new observation',
      (t) async {
    final sample = arrival(at: now.toIso8601String());
    Widget view(DateTime at) => MaterialApp(
            home: Scaffold(
                body: RouteDataStatus(
          source: 'PUBLIC_API',
          arrivals: [sample],
          now: at,
        )));
    await t.pumpWidget(view(now));
    expect(find.textContaining('이후 운행 변동 가능'), findsOneWidget);
    await t.pumpWidget(view(now.add(const Duration(seconds: 30))));
    expect(find.textContaining('30초 이상 지난'), findsOneWidget);
    expect(sample.updatedAt, now);
    await t.pumpWidget(const SizedBox());
  });
}
