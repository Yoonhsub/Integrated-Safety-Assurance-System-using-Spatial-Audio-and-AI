import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/cue_control.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/obstacle_cue_input.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/native_cue_output.dart';

ObstacleCueSnapshot snapshot(ObstacleRisk risk,
        {double angle = -45, int at = 0}) =>
    ObstacleCueSnapshot(observedAt: Duration(milliseconds: at), observations: [
      ObstacleCueObservation(id: 'one', risk: risk, roadAngleDegrees: angle),
    ]);
const target = CueObject(
    id: 'bus',
    kind: CueObjectKind.target,
    distance: CueDistance.near,
    angleDegrees: 0,
    observedAt: Duration.zero);
CueDecision decide(CueController controller, Iterable<CueObject> obstacles,
        {int now = 0, double yaw = 0}) =>
    controller.tick(
        now: Duration(milliseconds: now),
        context: CueContext.walking,
        objects: [target, ...obstacles],
        headYaw: yaw);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('no identification input leaves bus cue unchanged', () {
    expect(decide(CueController(), []).selection!.object.kind,
        CueObjectKind.target);
  });
  test('explicit danger preempts bus, disappearance restores fresh bus', () {
    final controller = CueController();
    final warning =
        decide(controller, snapshot(ObstacleRisk.danger).toCueObjects());
    expect(warning.selection!.object.id, 'obstacle:one');
    expect(warning.selection!.priority, 3);
    expect(decide(controller, [], now: 100).selection!.object.id, 'bus');
  });
  test('risk is explicit and independent of legacy distance inference', () {
    expect(
        decide(CueController(), snapshot(ObstacleRisk.none).toCueObjects())
            .selection!
            .object
            .id,
        'bus');
    expect(
        decide(CueController(), snapshot(ObstacleRisk.caution).toCueObjects())
            .selection!
            .priority,
        2);
  });
  test('capture time is retained: stale and future obstacles do not sound', () {
    final old = snapshot(ObstacleRisk.danger).toCueObjects();
    expect(decide(CueController(), old, now: 2000).selection!.object.id, 'bus');
    expect(
        decide(CueController(),
                snapshot(ObstacleRisk.danger, at: 100).toCueObjects())
            .selection!
            .object
            .id,
        'bus');
  });
  test(
      'road direction is corrected using head yaw; rear hazard does not become front',
      () {
    final objects = snapshot(ObstacleRisk.danger, angle: 45).toCueObjects();
    expect(
        decide(CueController(), objects, yaw: 45)
            .selection!
            .direction
            .targetAngle,
        0);
    final rear = decide(CueController(),
            snapshot(ObstacleRisk.danger, angle: 180).toCueObjects())
        .selection!;
    expect(rear.usesHrtf, isTrue);
    expect(rear.direction.targetAngle.abs(), 180);
    expect(rear.direction.left, rear.direction.right);
  });
  test('invalid directions, duplicate IDs and oversized input are rejected',
      () {
    expect(
        () => snapshot(ObstacleRisk.danger, angle: double.nan).toCueObjects(),
        throwsArgumentError);
    const observation = ObstacleCueObservation(
        id: 'x', risk: ObstacleRisk.danger, roadAngleDegrees: 0);
    expect(
        () => ObstacleCueSnapshot(
            observedAt: Duration.zero,
            observations: [observation, observation]).toCueObjects(),
        throwsArgumentError);
    expect(
        () => ObstacleCueSnapshot(
                observedAt: Duration.zero,
                observations: List.filled(65, observation))
            .toCueObjects(),
        throwsArgumentError);
  });
  test('native channel receives distinct bus and obstacle sound patterns',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCueOutput.channel, (call) async {
      calls.add(call);
      return {'running': true, 'route': 'test'};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCueOutput.channel, null));
    final output = NativeCueOutput(() => const ToneInput(0, -1, 900));
    await output.play(decide(CueController(), []).selection!);
    await output.play(
        decide(CueController(), snapshot(ObstacleRisk.danger).toCueObjects())
            .selection!);
    expect(calls[0].arguments['pattern'], 'target');
    expect(calls[0].arguments['intervalMs'], 900);
    expect((calls[0].arguments as Map).containsKey('azimuthDegrees'), isFalse);
    expect(calls[1].arguments['pattern'], 'warning');
    expect(calls[1].arguments['intervalMs'], 500);
    expect(calls[1].arguments['azimuthDegrees'], -45);
  });
}
