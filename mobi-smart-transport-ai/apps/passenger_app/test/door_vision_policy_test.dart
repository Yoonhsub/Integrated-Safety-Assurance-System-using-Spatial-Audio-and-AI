import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/door_approach_guard.dart';
import 'package:mobi_passenger_app/src/services/door_vision_policy.dart';

Map<String, Object?> cameraResult(String id, List<Object> detections) => {
      'schemaVersion': '1.0.0',
      'status': 'ok',
      'source': 'android_camera',
      'frameId': id,
      'capturedAt': '2026-11-11T00:00:00Z',
      'detections': detections
    };
Map<String, Object?> box(String type, double x, {double confidence = .9}) => {
      'classId': type,
      'confidence': confidence,
      'bbox': {'x': x, 'y': .1, 'w': .1, 'h': .5}
    };

void main() {
  const at = Duration(seconds: 1);
  test(
      'only detected obstacle classes become rehearsal caution with screen pan',
      () {
    final value = DoorVisionPolicy().evaluate(
        cameraResult('a', [
          box('bus', .1),
          box('parked_pm', .1),
          box('pole', .8),
          box('tree_trunk', .45),
          box('bus_door', .5)
        ]),
        capturedAt: at,
        now: at);
    expect(value.map((e) => e.pan), [-1, 1, 0]);
    expect(value.every((e) => e.risk == DoorRisk.caution), true);
  });
  test('unknown or low-confidence classes cannot silently become clear input',
      () {
    for (final item in [box('person', .1), box('pole', .1, confidence: .54)]) {
      expect(
          () => DoorVisionPolicy()
              .evaluate(cameraResult('a', [item]), capturedAt: at, now: at),
          throwsFormatException);
    }
  });
  test('future stale reversed and duplicate captures never become fresh frames',
      () {
    final policy = DoorVisionPolicy();
    final data = cameraResult('a', []);
    policy.evaluate(data, capturedAt: at, now: at);
    for (final capture in [Duration.zero, at, const Duration(seconds: 4)]) {
      expect(
          () => policy.evaluate(cameraResult('b', []),
              capturedAt: capture, now: const Duration(seconds: 3)),
          throwsFormatException);
    }
    expect(
        () => policy.evaluate(data,
            capturedAt: const Duration(seconds: 2),
            now: const Duration(seconds: 2)),
        throwsFormatException);
  });
  test('only real camera success snapshots are accepted by live source', () {
    for (final data in [
      {...cameraResult('a', []), 'status': 'unavailable'},
      {...cameraResult('a', []), 'source': 'mock'},
      {...cameraResult('a', []), 'capturedAt': null}
    ]) {
      expect(() => DoorVisionPolicy().evaluate(data, capturedAt: at, now: at),
          throwsFormatException);
    }
    expect(
        DoorVisionPolicy()
            .evaluate(cameraResult('empty', []), capturedAt: at, now: at),
        isEmpty);
  });
  test(
      'camera invalidation is immediate even at last snapshot time and gates resume',
      () {
    final guard = DoorApproachGuard(targetId: 'A')..start(Duration.zero);
    guard.observeObstacles(at: at, now: at, obstacles: const []);
    guard.observeTarget(
        id: 'A',
        at: const Duration(seconds: 2),
        now: const Duration(seconds: 2),
        proximity: DoorProximity.near);
    expect(guard.current.phase, DoorPhase.near);
    guard.invalidatePerception(const Duration(seconds: 2));
    expect(guard.current.phase, DoorPhase.unavailable);
    guard.observeObstacles(
        at: const Duration(milliseconds: 2100),
        now: const Duration(milliseconds: 2100),
        obstacles: const []);
    expect(guard.current.approaching, false);
    guard.observeTarget(
        id: 'A',
        at: const Duration(milliseconds: 2200),
        now: const Duration(milliseconds: 2200),
        proximity: DoorProximity.near);
    expect(guard.current.phase, DoorPhase.near);
  });
}
