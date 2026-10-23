import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_ble_temp/cue_control.dart';
import 'package:mobi_ble_temp/direction_pan.dart';

CueObject object(
  String id, {
  CueObjectKind kind = CueObjectKind.target,
  CueDistance distance = CueDistance.near,
  double angle = 0,
  int at = 0,
}) => CueObject(
  id: id,
  kind: kind,
  distance: distance,
  angleDegrees: angle,
  observedAt: Duration(milliseconds: at),
);
CueDecision tick(
  CueController c,
  List<CueObject> objects, {
  int now = 0,
  CueContext context = CueContext.walking,
  bool ready = true,
  double yaw = 0,
}) => c.tick(
  now: Duration(milliseconds: now),
  context: context,
  objects: objects,
  headYaw: yaw,
  inputReady: ready,
);

class FakeOutput implements CueOutput {
  final calls = <String>[];
  int concurrent = 0, peak = 0;
  Completer<void>? delayedStart;
  bool failPlay = false;
  Future<void> operation(String value) async {
    concurrent++;
    if (concurrent > peak) peak = concurrent;
    calls.add(value);
    try {
      if (value.startsWith('play:')) {
        if (failPlay) throw StateError('fake output failure');
        await delayedStart?.future;
      }
    } finally {
      concurrent--;
    }
  }

  @override
  Future<void> play(CueSelection cue) => operation('play:${cue.object.id}');
  @override
  Future<void> stop() => operation('stop');
  @override
  Future<void> update(CueSelection cue) => operation('update:${cue.object.id}');
}

void main() {
  test(
    'hazard preempts goal, then fresh goal resumes without overlap',
    () async {
      final c = CueController();
      final sink = FakeOutput();
      final driver = CueOutputDriver(sink);
      final target = object('goal');
      final hazard = object('hazard', kind: CueObjectKind.obstacle);
      await driver.apply(tick(c, [target]));
      final warn = tick(c, [target, hazard], now: 100);
      expect(warn.selection!.priority, 3);
      await driver.apply(warn);
      final resume = tick(c, [target], now: 200);
      expect(resume.selection!.object.id, 'goal');
      await driver.apply(resume);
      expect(sink.calls, [
        'stop',
        'play:goal',
        'stop',
        'play:hazard',
        'stop',
        'play:goal',
      ]);
      expect(sink.peak, 1);
    },
  );
  test('meaning, distance and context filter irrelevant objects', () {
    final c = CueController();
    final medium = object(
      'risk',
      kind: CueObjectKind.obstacle,
      distance: CueDistance.medium,
    );
    final far = object(
      'far',
      kind: CueObjectKind.obstacle,
      distance: CueDistance.far,
    );
    final irrelevant = object('irrelevant', kind: CueObjectKind.irrelevant);
    expect(
      tick(c, [medium, far, irrelevant], context: CueContext.waiting).action,
      CueAction.none,
    );
    expect(tick(c, [medium], now: 10).selection!.priority, 2);
    expect(
      tick(c, [medium], now: 20, context: CueContext.complete).action,
      CueAction.stop,
    );
  });
  test('same risk wins regardless of input order; near outranks medium', () {
    final a = object('a', kind: CueObjectKind.obstacle);
    final b = object('b', kind: CueObjectKind.obstacle);
    final medium = object(
      '0',
      kind: CueObjectKind.obstacle,
      distance: CueDistance.medium,
    );
    expect(tick(CueController(), [b, medium, a]).selection!.object.id, 'a');
    expect(tick(CueController(), [a, medium, b]).selection!.object.id, 'a');
  });
  test(
    'risk and goal expire at their exact TTL without stale goal revival',
    () {
      final c = CueController();
      final target = object('goal');
      final risk = object('risk', kind: CueObjectKind.obstacle);
      tick(c, [target, risk]);
      expect(tick(c, [target, risk], now: 2000).selection!.object.id, 'goal');
      expect(tick(c, [target, risk], now: 3000).action, CueAction.stop);
      expect(tick(c, [target, risk], now: 4000).selection, isNull);
    },
  );
  test(
    'duplicate snapshots do not retrigger; direction changes update only',
    () {
      final c = CueController();
      final target = object('goal');
      expect(tick(c, [target]).action, CueAction.play);
      expect(tick(c, [target], now: 100).action, CueAction.none);
      final rotated = tick(c, [target], now: 200, yaw: 45);
      expect(rotated.action, CueAction.update);
      expect(rotated.selection!.direction.cue, FiveWayCue.frontLeft);
    },
  );
  test('brief goal disappearance respects cooldown; danger bypasses it', () {
    final c = CueController();
    final target = object('goal');
    tick(c, [target]);
    expect(tick(c, [], now: 100).action, CueAction.stop);
    expect(tick(c, [target], now: 200).action, CueAction.none);
    expect(
      tick(c, [object('risk', kind: CueObjectKind.obstacle)], now: 201).action,
      CueAction.play,
    );
  });
  test('cooldown elapses and valid goal can restart', () {
    final c = CueController();
    final target = object('goal');
    tick(c, [target]);
    tick(c, [], now: 100);
    expect(tick(c, [target], now: 799).action, CueAction.none);
    expect(tick(c, [target], now: 800).action, CueAction.play);
  });
  test('cancel and reset require explicit resume', () {
    final c = CueController();
    final target = object('goal');
    tick(c, [target]);
    expect(c.cancel().action, CueAction.stop);
    expect(tick(c, [target], now: 1000).action, CueAction.none);
    c.resume();
    expect(tick(c, [target], now: 1001).action, CueAction.play);
    expect(c.reset().action, CueAction.stop);
    expect(tick(c, [target]).action, CueAction.none);
    c.resume();
    expect(tick(c, [target]).action, CueAction.play);
  });
  test('future, nonfinite and expired observations cannot play', () {
    final c = CueController();
    expect(
      tick(c, [
        object('future', at: 100),
        object('nan', angle: double.nan),
      ]).selection,
      isNull,
    );
    expect(tick(c, [object('negative', at: -1)]).selection, isNull);
    expect(() => tick(c, [], now: -1), throwsArgumentError);
    tick(c, [], now: 10);
    expect(() => tick(c, [], now: 9), throwsArgumentError);
  });
  test('invalid IDs and oversized snapshots stop current output', () {
    final c = CueController();
    final target = object('goal');
    tick(c, [target]);
    expect(tick(c, [target, target], now: 1).action, CueAction.stop);
    tick(c, [object('risk', kind: CueObjectKind.obstacle)], now: 2);
    expect(
      tick(c, List.generate(65, (i) => object('$i')), now: 3).action,
      CueAction.stop,
    );
    expect(tick(c, [object(' ')], now: 4).selection, isNull);
  });
  test('stale head input and rear hazard never fall through to target', () {
    final c = CueController();
    final target = object('goal');
    tick(c, [target]);
    expect(tick(c, [target], now: 10, ready: false).action, CueAction.stop);
    expect(
      tick(c, [
        target,
        object('rear', kind: CueObjectKind.obstacle, angle: 180),
      ], now: 20).selection,
      isNull,
    );
  });
  test(
    'direction hysteresis resists both boundaries and resets between targets',
    () {
      final tracker = DirectionCueTracker();
      DirectionPan read(double angle) =>
          tracker.track(DirectionPan.fromZ(0, 0, objectAngle: angle));
      expect(read(22).cue, FiveWayCue.front);
      expect(read(24).cue, FiveWayCue.front);
      expect(read(26).cue, FiveWayCue.frontRight);
      expect(read(21).cue, FiveWayCue.frontRight);
      expect(read(19).cue, FiveWayCue.front);
      expect(read(-24).cue, FiveWayCue.front);
      expect(read(-26).cue, FiveWayCue.frontLeft);
      tracker.reset();
      expect(read(-24).cue, FiveWayCue.frontLeft);
      expect(read(180).supported, isFalse);
      expect(read(24).cue, FiveWayCue.frontRight);
    },
  );
  test('old in-flight start is stopped before new cue starts', () async {
    final sink = FakeOutput()..delayedStart = Completer<void>();
    final driver = CueOutputDriver(sink);
    final c = CueController();
    final first = driver.apply(tick(c, [object('goal')]));
    await Future<void>.delayed(Duration.zero);
    final second = driver.apply(
      tick(c, [object('risk', kind: CueObjectKind.obstacle)], now: 10),
    );
    sink.delayedStart!.complete();
    await first;
    await second;
    expect(sink.calls, ['stop', 'play:goal', 'stop', 'stop', 'play:risk']);
    expect(sink.peak, 1);
  });
  test('output error is reported, stopped, and queue recovers', () async {
    final sink = FakeOutput()..failPlay = true;
    final driver = CueOutputDriver(sink);
    final c = CueController();
    await expectLater(
      driver.apply(tick(c, [object('goal')])),
      throwsStateError,
    );
    expect(sink.calls.last, 'stop');
    sink.failPlay = false;
    await driver.apply(
      tick(c, [object('risk', kind: CueObjectKind.obstacle)], now: 10),
    );
    expect(sink.calls.last, 'play:risk');
  });
}
