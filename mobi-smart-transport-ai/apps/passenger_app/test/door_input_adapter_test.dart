import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'package:mobi_passenger_app/src/services/door_input_adapter.dart';
import 'package:mobi_passenger_app/src/services/door_approach_guard.dart';

void main() {
  final wall = DateTime.utc(2026, 11, 11);
  const t = Duration(seconds: 10);
  BeaconSignal signal(String id, DateTime at) => BeaconSignal(
      beaconId: id,
      rssi: -55,
      estimatedDistanceMeters: null,
      signalLevel: BeaconSignalLevel.close,
      lastDetectedAt: at);
  test(
      'capture age survives conversion, repeats and other beacon cannot refresh target',
      () {
    final guard = DoorApproachGuard(targetId: 'A')
      ..start(t - const Duration(milliseconds: 1));
    final input = DoorBeaconInput(guard);
    guard.observeObstacles(
        at: t - const Duration(milliseconds: 1),
        now: t - const Duration(milliseconds: 1),
        obstacles: const []);
    expect(input.observe(signal('A', wall), wallNow: wall, now: t), true);
    expect(guard.current.phase, DoorPhase.near);
    expect(
        input.observe(signal('A', wall),
            wallNow: wall.add(const Duration(seconds: 1)),
            now: t + const Duration(seconds: 1)),
        false);
    expect(
        input.observe(signal('B', wall.add(const Duration(seconds: 3))),
            wallNow: wall.add(const Duration(seconds: 3)),
            now: t + const Duration(seconds: 3)),
        false);
    guard.observeObstacles(
        at: t + const Duration(seconds: 3),
        now: t + const Duration(seconds: 3),
        obstacles: const []);
    expect(guard.current.approaching, false);
  });
  test('stale future and pre-session callback timestamps are rejected', () {
    final input = DoorBeaconInput(DoorApproachGuard(targetId: 'A'));
    for (final stamp in [
      wall.subtract(const Duration(seconds: 3)),
      wall.add(const Duration(seconds: 1))
    ]) {
      expect(input.observe(signal('A', stamp), wallNow: wall, now: t), false);
    }
    expect(
        input.observe(signal('A', wall.subtract(const Duration(seconds: 1))),
            wallNow: wall, now: const Duration(milliseconds: 100)),
        false);
  });
  Map<String, dynamic> snapshot(List<dynamic> detections) => {
        'schemaVersion': '1.0.0',
        'source': 'mock',
        'status': 'ok',
        'frameId': 'frame1',
        'capturedAt': '2026-05-22T09:00:00+09:00',
        'detections': detections
      };
  Map<String, dynamic> detection(double x) => {
        'classId': 'pole',
        'confidence': .9,
        'bbox': {'x': x, 'y': .1, 'w': .1, 'h': .5}
      };
  test(
      'vision contract preserves evidence and uses screen direction with explicit mock risk',
      () {
    final replay = DoorVisionReplay.parse(
        jsonEncode(snapshot([
          detection(.1),
          detection(.8),
          {'classId': 'obstacle', 'confidence': .8}
        ])),
        testRisk: DoorRisk.danger);
    expect(replay.originalSource, 'mock');
    expect(replay.capturedAt, '2026-05-22T09:00:00+09:00');
    expect(replay.obstacles.map((e) => e.pan), [-1, 1, null]);
    expect(replay.obstacles.every((e) => e.risk == DoorRisk.danger), true);
  });
  test(
      'malformed geometry unavailable detector and silent risk clearing are rejected',
      () {
    for (final data in [
      snapshot([detection(.99)]),
      {...snapshot([]), 'status': 'unavailable'},
      snapshot([
        {'classId': 'pole', 'confidence': 2}
      ])
    ]) {
      expect(
          () => DoorVisionReplay.parse(jsonEncode(data),
              testRisk: DoorRisk.danger),
          throwsFormatException);
    }
    expect(
        () => DoorVisionReplay.parse(jsonEncode(snapshot([detection(.1)])),
            testRisk: DoorRisk.none),
        throwsFormatException);
    expect(
        DoorVisionReplay.parse(jsonEncode(snapshot([])),
                testRisk: DoorRisk.none)
            .obstacles,
        isEmpty);
  });
}
