import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/door_approach_guard.dart';

Duration ms(int n) => Duration(milliseconds: n);
void clear(DoorApproachGuard g, int t) =>
    g.observeObstacles(at: ms(t), now: ms(t), obstacles: const []);
void beacon(DoorApproachGuard g, int t,
        {DoorProximity zone = DoorProximity.approaching, String id = 'A'}) =>
    g.observeTarget(id: id, at: ms(t), now: ms(t), proximity: zone);
DoorApproachGuard ready() {
  final g = DoorApproachGuard(targetId: 'A');
  clear(g, 0);
  beacon(g, 1);
  g.start(ms(1));
  return g;
}

void main() {
  test('no perception or beacon means hold, never permission to advance', () {
    final g = DoorApproachGuard(targetId: 'A')..start(Duration.zero);
    beacon(g, 1);
    expect(g.current.approaching, isFalse);
    clear(g, 2);
    expect(g.current.phase, DoorPhase.awaitingTarget);
    beacon(g, 3);
    expect(g.current.phase, DoorPhase.approaching);
  });
  test('highest risk wins and unknown direction uses center', () {
    final g = ready();
    g.observeObstacles(at: ms(2), now: ms(2), obstacles: const [
      DoorObstacle('caution', DoorRisk.caution, pan: -1),
      DoorObstacle('danger', DoorRisk.danger),
    ]);
    expect(g.current.phase, DoorPhase.warning);
    expect(g.current.pan, 0);
    expect(g.current.text, contains('danger'));
  });
  test('target observed during warning cannot resume after explicit clear', () {
    final g = ready();
    g.observeObstacles(
        at: ms(10),
        now: ms(10),
        obstacles: const [DoorObstacle('x', DoorRisk.danger, pan: 1)]);
    beacon(g, 20);
    clear(g, 30);
    expect(g.current.phase, DoorPhase.awaitingTarget);
    beacon(g, 31, id: 'WRONG');
    expect(g.current.phase, DoorPhase.awaitingTarget);
    expect(
        g.observeTarget(
            id: 'A', at: ms(20), now: ms(32), proximity: DoorProximity.near),
        isFalse);
    expect(g.current.approaching, isFalse);
    beacon(g, 33);
    expect(g.current.phase, DoorPhase.approaching);
  });
  test('silence with no callbacks expires beacon on tick', () {
    final g = ready();
    clear(g, 2000);
    expect(g.tick(ms(3001)).phase, DoorPhase.unavailable);
    expect(g.current.text, '탑승 위치를 다시 확인해 주세요');
    beacon(g, 3002);
    expect(g.current.phase, DoorPhase.approaching);
  });
  test('expired risk is unknown, not an obstacle-clear event', () {
    final g = ready();
    g.observeObstacles(
        at: ms(10),
        now: ms(10),
        obstacles: const [DoorObstacle('x', DoorRisk.danger)]);
    beacon(g, 2010);
    expect(g.current.phase, DoorPhase.unavailable);
    clear(g, 2011);
    expect(g.current.phase, DoorPhase.awaitingTarget);
    beacon(g, 2012);
    expect(g.current.phase, DoorPhase.approaching);
  });
  test('future, stale, duplicate, wrong target do not refresh accepted time',
      () {
    final g = ready();
    for (final at in [ms(1), ms(5000), ms(-1)]) {
      expect(
          g.observeTarget(
              id: 'A', at: at, now: ms(100), proximity: DoorProximity.near),
          isFalse);
    }
    beacon(g, 2000, id: 'B');
    clear(g, 2000);
    expect(g.tick(ms(3001)).phase, DoorPhase.unavailable);
  });
  test(
      'invalid obstacle snapshot fails closed and recovery needs a fresh target',
      () {
    final g = ready();
    expect(
        g.observeObstacles(at: ms(2), now: ms(2), obstacles: const [
          DoorObstacle('x', DoorRisk.none),
          DoorObstacle('x', DoorRisk.danger),
        ]),
        isFalse);
    expect(g.current.phase, DoorPhase.unavailable);
    beacon(g, 3);
    clear(g, 4);
    expect(g.current.phase, DoorPhase.awaitingTarget);
    beacon(g, 5);
    expect(g.current.approaching, isTrue);
  });
  test('arrival requires fresh near state and remains manual', () {
    final g = ready();
    expect(g.confirmArrival(ms(2)), isFalse);
    beacon(g, 3, zone: DoorProximity.near);
    expect(g.current.phase, DoorPhase.near);
    expect(g.current.text, contains('문과 발밑'));
    expect(g.current.phase, isNot(DoorPhase.arrived));
    expect(g.confirmArrival(ms(4)), isTrue);
    beacon(g, 5);
    expect(g.current.phase, DoorPhase.arrived);
  });
  test(
      'stop does not resume from incoming packets; explicit start and new sample needed',
      () {
    final g = ready()..stop(ms(2));
    beacon(g, 3);
    expect(g.current.phase, DoorPhase.stopped);
    g.start(ms(4));
    expect(g.current.phase, DoorPhase.approaching);
  });
  test('clock reversal latches stopped until a new session', () {
    final g = ready();
    g.tick(Duration.zero);
    g.start(ms(100));
    expect(g.current.phase, DoorPhase.stopped);
  });
}
