import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobi_passenger_app/src/app.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/bus_passage.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/hardware_bus_page.dart';

void sample(BusPassage p, int rssi, int ms) =>
    p.observe(rssi, Duration(milliseconds: ms));
void stopInFront(BusPassage p) {
  sample(p, -85, 0);
  sample(p, -70, 200);
  sample(p, -54, 400);
  sample(p, -53, 1000);
  sample(p, -52, 2000);
}

void main() {
  test('left approach, sustained near stop, right departure', () {
    final p = BusPassage();
    sample(p, -85, 0);
    expect(p.angle, -90);
    sample(p, -70, 200);
    expect(p.angle, lessThan(0));
    sample(p, -54, 400);
    sample(p, -53, 1000);
    expect(p.phase, BusPassagePhase.approaching);
    sample(p, -52, 2000);
    expect(p.phase, BusPassagePhase.stopped);
    expect(p.angle, 0);
    sample(p, -62, 2600);
    sample(p, -62, 3000);
    expect(p.phase, BusPassagePhase.stopped);
    sample(p, -64, 3500);
    expect(p.phase, BusPassagePhase.departing);
    expect(p.angle, greaterThan(0));
    sample(p, -85, 4000);
    expect(p.angle, 90);
  });
  test('a single RSSI spike and a single dip do not change phase', () {
    final p = BusPassage();
    sample(p, -85, 0);
    sample(p, -45, 100);
    sample(p, -85, 200);
    sample(p, -85, 2200);
    expect(p.phase, BusPassagePhase.approaching);
    p.reset();
    stopInFront(p);
    sample(p, -75, 2100);
    sample(p, -52, 2200);
    expect(p.phase, BusPassagePhase.stopped);
  });
  test('lost signal gap resets passage; stale and invalid samples rejected',
      () {
    final p = BusPassage();
    stopInFront(p);
    sample(p, -80, 5000);
    expect(p.phase, BusPassagePhase.approaching);
    final angle = p.angle;
    sample(p, -40, 4900);
    expect(p.angle, angle);
    expect(() => sample(p, 1, 6000), throwsArgumentError);
    expect(() => sample(p, -55, -1), throwsArgumentError);
  });
  test('separate bus state cannot leak across target changes', () {
    final a = BusPassage(), b = BusPassage();
    stopInFront(a);
    sample(b, -85, 0);
    expect(a.angle, 0);
    expect(b.angle, -90);
    a.reset();
    expect(a.angle, -90);
  });
  testWidgets('Passenger app opens real hardware screen without backend',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MobiApp());
    await tester.pumpAndSettle();
    expect(find.text('Mock 데이터 테스트'), findsOneWidget);
    await tester.ensureVisible(find.text('실기기 연동확인'));
    await tester.tap(find.text('실기기 연동확인'));
    await tester.pumpAndSettle();
    expect(find.byType(HardwareBusPage), findsOneWidget);
    expect(find.text('main 기본 예시 시나리오와 연결'), findsNothing);
    expect(find.text('예시 재생'), findsNothing);
    expect(find.text('버스 탐색 시작 (5분)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('approach spike cannot become the departure peak after docking', () {
    final p = BusPassage();
    sample(p, -45, 0);
    sample(p, -80, 100);
    sample(p, -54, 500);
    sample(p, -54, 1000);
    sample(p, -54, 2100);
    expect(p.phase, BusPassagePhase.stopped);
    sample(p, -55, 2300);
    sample(p, -55, 2800);
    sample(p, -55, 3200);
    expect(p.phase, BusPassagePhase.stopped);
  });
}
